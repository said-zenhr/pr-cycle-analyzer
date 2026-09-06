require 'open3'
require 'json'
require 'fileutils'
require 'time'

# gh calls, pagination, raw persistence.
module Fetch
  PR_FIELDS = %w[
    number title url author createdAt mergedAt isDraft labels baseRefName
    additions deletions changedFiles reviews comments
  ].join(',')

  TIMELINE_QUERY = <<~GQL
    query($owner:String!, $repo:String!, $cursor:String) {
      repository(owner:$owner, name:$repo) {
        pullRequests(states:MERGED, first:50, after:$cursor,
                     orderBy:{field:UPDATED_AT, direction:DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number
            timelineItems(first:100, itemTypes:[READY_FOR_REVIEW_EVENT,
                          CONVERT_TO_DRAFT_EVENT, REVIEW_REQUESTED_EVENT,
                          HEAD_REF_FORCE_PUSHED_EVENT]) {
              nodes {
                __typename
                ... on ReadyForReviewEvent { createdAt }
                ... on ConvertToDraftEvent { createdAt }
                ... on ReviewRequestedEvent { createdAt }
                ... on HeadRefForcePushedEvent { createdAt }
              }
            }
          }
        }
      }
    }
  GQL

  module_function

  # Fetches one repo, persists raw, returns the raw hash.
  def sync(repo, limit: 500, since: nil, data_dir: 'data')
    owner, name = repo.split('/')
    raise ArgumentError, "repo must be OWNER/NAME, got #{repo.inspect}" unless owner && name

    prs = list_prs(repo, limit, since)

    raw = { 'repo' => repo, 'fetched_at' => Time.now.utc.iso8601,
            'prs' => prs, 'timeline' => timelines(owner, name, prs.map { |p| p['number'] }) }

    path = File.join(data_dir, 'raw', repo, "#{Time.now.utc.strftime('%Y-%m-%d')}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(raw))
    warn "  raw -> #{path} (#{prs.size} PRs)"
    raw
  end

  # gh pr list has no cursor and 504s on big repos past ~25 PRs with reviews+comments
  # attached, so page backwards through created: date windows and dedupe by number.
  PAGE = 25

  def list_prs(repo, limit, since)
    seen = {}
    before = nil
    loop do
      search = ['sort:created-desc']
      search << "created:<=#{before}" if before
      batch = gh('pr', 'list', '--repo', repo, '--state', 'merged', '--limit', PAGE.to_s,
                 '--search', search.join(' '), '--json', PR_FIELDS)
      fresh = batch.reject { |pr| seen.key?(pr['number']) }
      fresh.each { |pr| seen[pr['number']] = pr }
      oldest = batch.map { |pr| Time.parse(pr['createdAt']) }.min
      break if fresh.empty? || batch.size < PAGE || seen.size >= limit
      break if since && oldest && oldest < since
      before = oldest.strftime('%Y-%m-%d')
    end
    prs = seen.values
    prs = prs.select { |pr| Time.parse(pr['mergedAt']) >= since } if since
    prs.sort_by { |pr| -pr['number'] }.first(limit)
  end

  # Pages GraphQL until every wanted PR number is covered or pages run out.
  def timelines(owner, name, wanted)
    wanted = wanted.to_a
    remaining = wanted.dup
    out = {}
    cursor = nil
    loop do
      args = ['api', 'graphql', '-f', "query=#{TIMELINE_QUERY}", '-f', "owner=#{owner}", '-f', "repo=#{name}"]
      args += ['-f', "cursor=#{cursor}"] if cursor
      page = gh(*args).dig('data', 'repository', 'pullRequests')
      page['nodes'].each do |node|
        next unless wanted.include?(node['number'])
        out[node['number'].to_s] = node.dig('timelineItems', 'nodes')
        remaining.delete(node['number'])
      end
      break if remaining.empty? || !page.dig('pageInfo', 'hasNextPage')
      cursor = page.dig('pageInfo', 'endCursor')
    end
    warn "  timeline: #{out.size}/#{wanted.size} PRs (#{remaining.size} unresolved)" unless remaining.empty?
    out
  end

  # GitHub 502/504s on heavy PR queries often enough that one retry pass is the
  # difference between a usable backfill and a coin flip.
  def gh(*args, tries: 3)
    attempt = 0
    begin
      attempt += 1
      out, err, status = Open3.capture3('gh', *args)
      raise "gh #{args.first(2).join(' ')} failed: #{err.strip}" unless status.success?
      JSON.parse(out)
    rescue RuntimeError => e
      raise if attempt >= tries || !e.message.match?(/HTTP 5\d\d|timeout|EOFError/)
      warn "  #{e.message.split("\n").first} — retry #{attempt}/#{tries - 1}"
      sleep(2**attempt)
      retry
    end
  end

  # Latest persisted raw file per repo, for recompute without re-fetch.
  def load_raw(data_dir: 'data', repos: nil)
    Dir.glob(File.join(data_dir, 'raw', '*', '*', '*.json')).group_by { |p| p.split('/')[-3, 2].join('/') }
       .select { |repo, _| repos.nil? || repos.include?(repo) }
       .map { |_, paths| JSON.parse(File.read(paths.max)) }
  end
end
