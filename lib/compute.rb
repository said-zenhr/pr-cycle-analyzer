require 'time'
require 'date'
require 'set'

# Pure: raw sync JSON -> flat rows. No I/O, no network.
# All correctness rules live here.
module Compute
  BOT_SUFFIX = '[bot]'.freeze

  # Not human, ever. These answer within minutes of a PR going ready, so leaving
  # any of them in reports pickup as ~0 for every PR in the repo. Structural, not
  # configurable — config/ignore.yml only adds to this.
  NEVER_HUMAN = %w[coderabbitai github-actions copilot copilot-pull-request-reviewer
                   dependabot renovate codecov sonarcloud].freeze
  # BOT_SUFFIX catches the [bot] form; NEVER_HUMAN catches the GitHub App logins
  # that arrive without it.

  # Amman: UTC+3 year-round since 2022, no DST, so a fixed offset is correct.
  # Work week Sunday-Thursday, 09:00-18:00. Public holidays are not modelled.
  OFFSET = '+03:00'.freeze
  WORK_DAYS = (0..4).freeze # Sunday..Thursday
  DAY_START = 9
  DAY_END = 18

  module_function

  # raw: {"repo" => "org/name", "prs" => [gh pr list nodes], "timeline" => {"123" => [events]}}
  # opts: bot_denylist: [logins], ignore: [pr numbers]
  def rows(raw, bot_denylist: [], ignore: [])
    repo   = raw['repo']
    deny   = bot_denylist.map(&:downcase).to_set
    ignore = ignore.map(&:to_i).to_set
    events = raw['timeline'] || {}

    raw['prs'].map do |pr|
      next if pr['mergedAt'].nil?           # rule 7: open/closed-unmerged excluded
      next if ignore.include?(pr['number']) # rule 9
      row(repo, pr, events[pr['number'].to_s] || [], deny)
    end.compact
  end

  def row(repo, pr, timeline, deny)
    author  = pr.dig('author', 'login')
    created = t(pr['createdAt'])
    merged  = t(pr['mergedAt'])
    flags   = []

    # rule 1: anchor on ready-for-review. Non-draft PRs: ready == created.
    readies = timeline.select { |e| e['__typename'] == 'ReadyForReviewEvent' }.map { |e| t(e['createdAt']) }
    ready   = readies.max || created
    flags << 'ready_from_timeline' unless readies.empty?
    flags << 'force_pushed' if timeline.any? { |e| e['__typename'] == 'HeadRefForcePushedEvent' }

    # rule 4: bots (and the author's own noise) never count as a response
    reviews = (pr['reviews'] || []).reject { |r| bot?(r['author'], deny) || r.dig('author', 'login') == author }
    comments = (pr['comments'] || []).reject { |c| bot?(c['author'], deny) || c.dig('author', 'login') == author }

    responses = reviews.map { |r| t(r['submittedAt']) } + comments.map { |c| t(c['createdAt']) }
    responses = responses.compact.select { |ts| ts >= ready }

    approvals = reviews.select { |r| r['state'] == 'APPROVED' }.map { |r| t(r['submittedAt']) }.compact

    first_response = responses.min
    approved       = approvals.max

    # rule 5, known causes: events after merge are not stage boundaries, they are noise.
    if first_response && first_response > merged
      flags << 'response_after_merge'
      first_response = nil
    end
    if approved && approved > merged
      flags << 'approval_after_merge'
      approved = nil
    end
    approved = nil if approved && first_response && approved < first_response

    # rule 3: broken review chain falls back so no elapsed time disappears.
    # One set of boundaries, both clocks derived from it — so the wall-clock and
    # working-hours segments cannot drift apart.
    spans =
      if first_response.nil?
        flags << 'no_review'
        [[ready, merged], nil, nil]
      elsif approved.nil?
        flags << 'no_approval'
        [[ready, first_response], [first_response, merged], nil]
      else
        [[ready, first_response], [first_response, approved], [approved, merged]]
      end

    pickup, review, merge_wait = spans.map { |a, b| a.nil? ? 0.0 : b - a }
    total = merged - ready
    # rule 5 fallthrough: clock skew / ready-after-merge. Clamp to nil, never emit as data.
    bh = spans.map { |a, b| a.nil? ? 0.0 : business_seconds(a, b) }
    if [pickup, review, merge_wait, total].any? { |s| s < 0 }
      flags << 'clamped_negative'
      pickup = review = merge_wait = total = nil
      bh = [nil, nil, nil]
    end

    {
      'number' => pr['number'], 'repo' => repo, 'url' => pr['url'], 'title' => pr['title'],
      'author' => author,
      'reviewers' => reviews.map { |r| r.dig('author', 'login') }.compact.uniq,
      'labels' => (pr['labels'] || []).map { |l| l['name'] },
      'base_branch' => pr['baseRefName'],
      'files_changed' => pr['changedFiles'],
      'lines_changed' => (pr['additions'] || 0) + (pr['deletions'] || 0),
      'created_at' => iso(created), 'ready_at' => iso(ready),
      'first_response_at' => iso(first_response), 'approved_at' => iso(approved),
      'merged_at' => iso(merged),
      'week' => week_of(merged),
      # rule 6: nil = not applicable. 0 = a genuine zero. draft is nil when the PR was never a draft.
      'draft_s' => readies.empty? ? nil : (ready - created),
      'pickup_s' => pickup, 'review_s' => review, 'merge_wait_s' => merge_wait,
      'total_s' => total,
      # Working-hours twins off the same boundaries. business_seconds is additive
      # over adjacent spans, so these sum to total_bh_s like the wall-clock ones.
      'draft_bh_s' => readies.empty? ? nil : business_seconds(created, ready),
      'pickup_bh_s' => bh[0], 'review_bh_s' => bh[1], 'merge_wait_bh_s' => bh[2],
      'total_bh_s' => total.nil? ? nil : business_seconds(ready, merged),
      'flags' => flags
    }
  end

  # Elapsed working seconds between two instants. A PR ready at 18:00 and
  # reviewed at 09:10 next morning waits 15h on the wall and 10 minutes at work.
  def business_seconds(from, to)
    return nil if from.nil? || to.nil?
    return 0.0 if to <= from
    a = from.getlocal(OFFSET)
    b = to.getlocal(OFFSET)
    total = 0.0
    day = Date.new(a.year, a.month, a.day)
    last = Date.new(b.year, b.month, b.day)
    while day <= last
      if WORK_DAYS.include?(day.wday)
        open_at  = Time.new(day.year, day.month, day.day, DAY_START, 0, 0, OFFSET)
        close_at = Time.new(day.year, day.month, day.day, DAY_END, 0, 0, OFFSET)
        lo = [a, open_at].max
        hi = [b, close_at].min
        total += hi - lo if hi > lo
      end
      day += 1
    end
    total
  end

  def bot?(author, deny)
    return true if author.nil?
    login = author['login'].to_s.downcase
    author['is_bot'] || login.end_with?(BOT_SUFFIX) ||
      NEVER_HUMAN.include?(login) || deny.include?(login)
  end

  def t(s)
    s.nil? || s.empty? ? nil : Time.parse(s).utc
  end

  def iso(time)
    time&.strftime('%Y-%m-%dT%H:%M:%SZ')
  end

  # Monday of the week the PR merged in.
  def week_of(time)
    (time.to_date - ((time.to_date.wday - 1) % 7)).to_s
  end
end
