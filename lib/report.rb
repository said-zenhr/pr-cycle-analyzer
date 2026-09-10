require 'erb'
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

  TEMPLATE = <<~ERB
    <!doctype html>
    <meta charset="utf-8"><title>PR cycle time — <%= group_by %></title>
    <style>
      body { font: 14px/1.5 -apple-system, system-ui, sans-serif; margin: 2rem auto; max-width: 60rem; color: #222; }
      h1 { font-size: 1.3rem; } h2 { font-size: 1.05rem; margin-top: 2.5rem; }
      .chart { display: flex; align-items: flex-end; gap: 14px; height: 320px; border-bottom: 1px solid #ccc; padding-top: 1rem; }
      .col { display: flex; flex-direction: column; justify-content: flex-end; flex: 1; min-width: 40px; }
      .bar { display: flex; flex-direction: column-reverse; }
      .seg { min-height: 1px; }
      .xlab { font-size: 11px; text-align: center; padding-top: 6px; color: #555; word-break: break-all; }
      .sup { color: #999; text-align: center; font-size: 11px; }
      .legend span { margin-right: 1rem; font-size: 12px; }
      .swatch { display: inline-block; width: 10px; height: 10px; margin-right: 4px; }
      table { border-collapse: collapse; width: 100%; font-size: 13px; }
      th, td { text-align: left; padding: 5px 8px; border-bottom: 1px solid #eee; }
      td.num { text-align: right; font-variant-numeric: tabular-nums; }
      code { font-size: 11px; color: #a33; }
    </style>
    <h1>PR cycle time by <%= group_by %></h1>
    <p>Working hours only — Sunday to Thursday, 09:00–18:00 Amman. Nights, weekends and the wall clock are in
    <code>data/computed/prs.json</code>.</p>
    <p class="legend">
      <% Report::COLORS.each do |seg, color| %>
        <span><i class="swatch" style="background:<%= color %>"></i><%= Report::LABELS[seg] %></span>
      <% end %>
      <span>median per bucket · tallest bar = <%= Report.h(max) %></span>
    </p>
    <div class="chart">
      <% buckets.each do |b| %>
        <div class="col">
          <% if b['suppressed'] %>
            <div class="sup">n=<%= b['n'] %><br>suppressed</div>
          <% else %>
            <div class="bar" title="total <%= Report.h(b['total']['median']) %> · n=<%= b['n'] %>">
              <% Report::COLORS.each do |seg, color| %>
                <% v = b['stages'][seg]['median'] || 0 %>
                <div class="seg" style="height:<%= (v / max * 280).round(1) %>px;background:<%= color %>"
                     title="<%= Report::LABELS[seg] %> <%= Report.h(v) %>"></div>
              <% end %>
            </div>
          <% end %>
          <div class="xlab"><%= b['bucket'] %></div>
        </div>
      <% end %>
    </div>
    <h2>Slowest <%= slowest.size %> PRs</h2>
    <table>
      <tr><th>PR</th><th>author</th><th class="num">total</th><th class="num">pickup</th>
          <th class="num">review</th><th class="num">merge-wait</th><th>flags</th></tr>
      <% slowest.each do |r| %>
        <tr>
          <td><a href="<%= r['url'] %>"><%= r['repo'] %>#<%= r['number'] %></a> <%= r['title'][0, 60] %></td>
          <td><%= r['author'] %></td>
          <td class="num"><%= Report.h(r['total_bh_s'], 0) %></td>
          <td class="num"><%= Report.h(r['pickup_bh_s'], 0) %></td>
          <td class="num"><%= Report.h(r['review_bh_s'], 0) %></td>
          <td class="num"><%= Report.h(r['merge_wait_bh_s'], 0) %></td>
          <td><code><%= r['flags'].join(' ') %></code></td>
        </tr>
      <% end %>
    </table>
  ERB

  def html(buckets, rows, group_by, path)
    shown = buckets.reject { |b| b['suppressed'] }
    max = shown.map { |b| Aggregate::SEGMENTS.sum { |s| b['stages'][s]['median'] || 0 } }.max || 1.0
    max = 1.0 if max.zero?
    slowest = slowest(rows)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, ERB.new(TEMPLATE, nil, '-').result(binding))
    path
  end
end
