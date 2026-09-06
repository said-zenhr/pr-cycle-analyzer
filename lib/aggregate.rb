require 'time'

# Filters, grouping, percentiles. Rows in, buckets out.
module Aggregate
  SEGMENTS = %w[pickup_s review_s merge_wait_s].freeze
  MIN_N = 10 # rule 8

  module_function

  # opts keys: repo, author, reviewer, label, base (arrays); min_size, max_size, since, until
  def filter(rows, opts)
    rows.select do |r|
      next false if opts[:repo]     && !opts[:repo].include?(r['repo'])
      next false if opts[:author]   && !opts[:author].include?(r['author'])
      next false if opts[:reviewer] && (opts[:reviewer] & r['reviewers']).empty?
      next false if opts[:label]    && (opts[:label] & r['labels']).empty?
      next false if opts[:base]     && !opts[:base].include?(r['base_branch'])
      next false if opts[:min_size] && r['lines_changed'] < opts[:min_size]
      next false if opts[:max_size] && r['lines_changed'] > opts[:max_size]
      merged = Time.parse(r['merged_at'])
      next false if opts[:since] && merged < opts[:since]
      next false if opts[:until] && merged > opts[:until]
      true
    end
  end

  # group_by: week | repo | author | reviewer | label
  # reviewer/label fan a PR out into every one of its values.
  def group(rows, key)
    case key
    when 'reviewer', 'label'
      field = key == 'reviewer' ? 'reviewers' : 'labels'
      rows.each_with_object({}) do |r, h|
        values = r[field].empty? ? ['(none)'] : r[field]
        values.each { |v| (h[v] ||= []) << r }
      end
    else
      rows.group_by { |r| r[key] || '(none)' }
    end
  end

  def buckets(rows, key)
    group(rows, key).sort_by(&:first).map { |name, rs| summarize(name, rs) }
  end

  def summarize(name, rows)
    scored = rows.reject { |r| r['total_s'].nil? } # clamped rows are counted, never averaged
    stats = SEGMENTS.each_with_object({}) do |seg, h|
      values = scored.map { |r| r[seg] }.compact
      h[seg] = { 'median' => percentile(values, 0.5), 'p75' => percentile(values, 0.75) }
    end
    totals = scored.map { |r| r['total_s'] }
    {
      'bucket' => name,
      'n' => scored.size,
      'flagged' => rows.count { |r| !r['flags'].empty? },
      'clamped' => rows.count { |r| r['flags'].include?('clamped_negative') },
      'suppressed' => scored.size < MIN_N,
      'stages' => stats,
      'total' => { 'median' => percentile(totals, 0.5), 'p75' => percentile(totals, 0.75) },
      'bottleneck' => stats.max_by { |_, v| v['median'] || -1 }&.first&.sub('_s', ''),
      'rows' => rows
    }
  end

  # Linear interpolation between closest ranks.
  def percentile(values, pct)
    return nil if values.empty?
    sorted = values.sort
    rank = pct * (sorted.size - 1)
    low, high = sorted[rank.floor], sorted[rank.ceil]
    low + (high - low) * (rank - rank.floor)
  end
end
