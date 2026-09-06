require 'time'
require 'date'
require 'set'

# Pure: raw sync JSON -> flat rows. No I/O, no network.
# All correctness rules live here.
module Compute
  BOT_SUFFIX = '[bot]'.freeze

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
    if first_response.nil?
      flags << 'no_review'
      pickup, review, merge_wait = merged - ready, 0.0, 0.0
    elsif approved.nil?
      flags << 'no_approval'
      pickup, review, merge_wait = first_response - ready, merged - first_response, 0.0
    else
      pickup     = first_response - ready
      review     = approved - first_response
      merge_wait = merged - approved
    end

    total = merged - ready
    # rule 5 fallthrough: clock skew / ready-after-merge. Clamp to nil, never emit as data.
    if [pickup, review, merge_wait, total].any? { |s| s < 0 }
      flags << 'clamped_negative'
      pickup = review = merge_wait = total = nil
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
      'flags' => flags
    }
  end

  def bot?(author, deny)
    return true if author.nil?
    login = author['login'].to_s
    author['is_bot'] || login.end_with?(BOT_SUFFIX) || deny.include?(login.downcase)
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
