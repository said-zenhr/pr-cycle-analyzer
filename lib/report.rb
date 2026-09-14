require 'erb'
require 'json'
require 'time'
require 'fileutils'

# ERB -> HTML, stdout summary.
module Report
  COLORS = { 'pickup_bh_s' => '#d95f02', 'review_bh_s' => '#1b9e77', 'merge_wait_bh_s' => '#7570b3' }.freeze
  LABELS = { 'pickup_bh_s' => 'pickup', 'review_bh_s' => 'review', 'merge_wait_bh_s' => 'merge-wait' }.freeze

  module_function

  def hours(seconds)
    seconds.nil? ? nil : (seconds / 3600.0)
  end

  def h(seconds, digits = 1)
    seconds.nil? ? '—' : format("%.#{digits}fh", hours(seconds))
  end

  # 256-colour ANSI, matched to the chart's segment colours. NO_COLOR or a pipe turns it off.
  ANSI = { 'pickup_bh_s' => 208, 'review_bh_s' => 35, 'merge_wait_bh_s' => 98 }.freeze
  BAR = 24

  def color?(io)
    return false unless ENV['NO_COLOR'].to_s.empty?
    io.tty? || !ENV['FORCE_COLOR'].to_s.empty?
  end

  def fg(text, code, io)
    color?(io) ? "\e[38;5;#{code}m#{text}\e[0m" : text
  end

  def bg(text, code, io)
    color?(io) ? "\e[48;5;#{code}m#{text}\e[0m" : text
  end

  def dim(text, io)
    color?(io) ? "\e[2m#{text}\e[0m" : text
  end

  def bold(text, io)
    color?(io) ? "\e[1m#{text}\e[0m" : text
  end

  SEP = ' │ '.freeze

  # A rule the same shape as the header, crossed wherever a column divider sits.
  def rule(head, char, io)
    dim(head.chars.map { |c| c == '│' ? '┼' : char }.join, io)
  end

  def stdout_summary(buckets, group_by, io = $stdout)
    io.print "\n\n" # breathing room between the command line and the table
    label = group_by == 'week' ? 'week of' : group_by
    w = [buckets.map { |b| b['bucket'].to_s.length }.max || 0, label.length].max
    fmt = ["%-#{w}s", '%4s', '%-16s', '%-16s', '%-16s', '%8s', '%8s', "%-#{BAR}s", '%s'].join(SEP)

    head = format(fmt, label, 'n', 'pickup', 'review', 'merge-wait', 'total', 'wall', 'split', 'bottleneck')
    io.puts bold(head, io)
    io.puts rule(head, '─', io)

    buckets.each_with_index do |b, i|
      io.puts rule(head, '┈', io) if i.positive?
      if b['suppressed']
        io.puts dim(format("%-#{w}s#{SEP}%4d#{SEP}n < #{Aggregate::MIN_N}, suppressed", b['bucket'], b['n']), io)
        next
      end
      st = b['stages']
      cells = ANSI.map do |seg, code|
        pad(fg(format('%7s', h(st[seg]['median'])), code, io) + dim(format(' p75 %-4s', h(st[seg]['p75'], 0)), io), 16)
      end
      io.puts format(fmt.sub('%4s', '%4d'), b['bucket'], b['n'], *cells,
                     bold(format('%8s', h(b['total']['median'])), io),
                     dim(format('%8s', h(b['wall']['median'])), io),
                     pad(bar(b, io), BAR),
                     fg(b['bottleneck'], ANSI.fetch("#{b['bottleneck'].tr('-', '_')}_s", 7), io))
      next if b['flagged'].zero?
      note = "#{b['flagged']} flagged" + (b['clamped'].positive? ? ", #{b['clamped']} clamped and excluded" : '')
      io.puts dim(format("%-#{w}s#{SEP}%4s#{SEP}%s", '', '', note), io)
    end

    marks = color?(io) ? ['  ', '  ', '  '] : %w[## == ..]
    key = ANSI.values.each_with_index.map { |code, i| bg(marks[i], code, io) + ' ' + LABELS.values[i] }.join('   ')
    io.puts "\n#{dim('working hours, Sun-Thu 09:00-18:00 Amman · wall = elapsed · p75 beside each median  ·  ', io)}#{key}"
  end

  # printf counts escape bytes, so pad on visible width.
  def pad(text, width)
    text + ' ' * [width - text.gsub(/\e\[[\d;]*m/, '').length, 0].max
  end

  # Proportional stacked bar, same three colours as the chart.
  def bar(bucket, io)
    values = ANSI.keys.map { |seg| bucket['stages'][seg]['median'] || 0 }
    total = values.sum
    return '' if total.zero?
    widths = values.map { |v| (v / total * BAR).round }
    widths[values.index(values.max)] += BAR - widths.sum
    chars = color?(io) ? [' ', ' ', ' '] : %w[# = .]
    ANSI.values.each_with_index.map { |code, i| bg(chars[i] * widths[i], code, io) }.join
  end

  def slowest_table(rows, io = $stdout, limit = 10)
    top = slowest(rows, limit)
    return if top.empty?
    w = top.map { |r| "#{r['repo']}##{r['number']}".length }.max
    io.puts "\n#{bold("slowest #{top.size} PRs", io)}"
    fmt = ["%-#{w}s", '%8s', '%8s', '%8s', '%8s', '%8s', '%-14s', '%-48s'].join(SEP)
    head = format(fmt, 'pr', 'total', 'wall', 'pickup', 'review', 'wait', 'author', 'title')
    io.puts bold(head, io)
    io.puts rule(head, '─', io)
    top.each_with_index do |r, i|
      io.puts rule(head, '┈', io) if i.positive?
      io.puts format(fmt,
                     "#{r['repo']}##{r['number']}",
                     pad(bold(format('%8s', h(r['total_bh_s'], 0)), io), 8),
                     pad(dim(format('%8s', h(r['total_s'], 0)), io), 8),
                     pad(fg(format('%8s', h(r['pickup_bh_s'], 0)), ANSI['pickup_bh_s'], io), 8),
                     pad(fg(format('%8s', h(r['review_bh_s'], 0)), ANSI['review_bh_s'], io), 8),
                     pad(fg(format('%8s', h(r['merge_wait_bh_s'], 0)), ANSI['merge_wait_bh_s'], io), 8),
                     r['author'].to_s[0, 14], dim(r['title'].to_s[0, 48], io))
      io.puts dim(format("%-#{w}s#{SEP}%s", '', r['flags'].join(' ')), io) unless r['flags'].empty?
    end
  end

  def slowest(rows, limit = 10)
    rows.reject { |r| r['total_bh_s'].nil? }.sort_by { |r| -r['total_bh_s'] }.first(limit)
  end

  def html(_buckets, rows, _group_by, path)
    rows_json = JSON.generate(rows)
    generated = Time.now.strftime('%Y-%m-%d %H:%M')
    template = File.read(File.expand_path('dashboard.html.erb', __dir__))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, ERB.new(template, nil, '-').result(binding))
    path
  end
end
