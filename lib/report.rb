require 'erb'
require 'fileutils'

# ERB -> HTML, stdout summary.
module Report
  COLORS = { 'pickup_s' => '#d95f02', 'review_s' => '#1b9e77', 'merge_wait_s' => '#7570b3' }.freeze
  LABELS = { 'pickup_s' => 'pickup', 'review_s' => 'review', 'merge_wait_s' => 'merge-wait' }.freeze

  module_function

  def hours(seconds)
    seconds.nil? ? nil : (seconds / 3600.0)
  end

  def h(seconds, digits = 1)
    seconds.nil? ? '—' : format("%.#{digits}fh", hours(seconds))
  end

  def stdout_summary(buckets, group_by, io = $stdout)
    buckets.each do |b|
      head = "#{group_by == 'week' ? 'week of ' : ''}#{b['bucket']}"
      if b['suppressed']
        io.puts "#{head}: n=#{b['n']} (suppressed)"
        next
      end
      s = b['stages']
      io.puts "#{head}: pickup #{h(s['pickup_s']['median'])} (p75 #{h(s['pickup_s']['p75'], 0)}) · " \
              "review #{h(s['review_s']['median'])} · merge-wait #{h(s['merge_wait_s']['median'])}"
      io.puts "#{' ' * (head.length + 2)}n=#{b['n']} · #{b['flagged']} flagged → bottleneck: #{b['bottleneck']}"
    end
  end

  def slowest(rows, limit = 10)
    rows.reject { |r| r['total_s'].nil? }.sort_by { |r| -r['total_s'] }.first(limit)
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
          <td class="num"><%= Report.h(r['total_s'], 0) %></td>
          <td class="num"><%= Report.h(r['pickup_s'], 0) %></td>
          <td class="num"><%= Report.h(r['review_s'], 0) %></td>
          <td class="num"><%= Report.h(r['merge_wait_s'], 0) %></td>
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
