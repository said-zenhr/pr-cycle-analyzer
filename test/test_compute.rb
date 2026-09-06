require 'minitest/autorun'
require 'json'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'compute'
require 'aggregate'

H = 3600.0

class ComputeTest < Minitest::Test
  def setup
    raw = JSON.parse(File.read(File.expand_path('fixtures/raw.json', __dir__)))
    @rows = Compute.rows(raw, bot_denylist: %w[dependabot], ignore: [9])
    @by_number = @rows.each_with_object({}) { |r, h| h[r['number']] = r }
  end

  def pr(n)
    @by_number.fetch(n)
  end

  # rule 2: the one invariant that catches every missing-anchor bug.
  def test_segments_sum_to_total
    @rows.reject { |r| r['total_s'].nil? }.each do |r|
      sum = r['pickup_s'] + r['review_s'] + r['merge_wait_s']
      assert_in_delta r['total_s'], sum, 0.001, "PR #{r['number']} segments do not sum to total"
    end
  end

  # rule 1: anchored on ready-for-review, not creation.
  def test_draft_anchors_on_ready
    r = pr(1)
    assert_equal '2026-09-02T00:00:00Z', r['ready_at']
    assert_equal 24 * H, r['draft_s']
    assert_equal 2 * H, r['pickup_s']
    assert_equal 10 * H, r['review_s']
    assert_equal 12 * H, r['merge_wait_s']
    assert_equal 24 * H, r['total_s']
  end

  def test_non_draft_ready_equals_created
    assert_equal pr(3)['created_at'], pr(3)['ready_at']
    assert_nil pr(3)['draft_s']
  end

  # rule 3
  def test_no_review_puts_everything_in_pickup
    r = pr(2)
    assert_includes r['flags'], 'no_review'
    assert_equal 5 * H, r['pickup_s']
    assert_equal 0.0, r['review_s']
    assert_equal 0.0, r['merge_wait_s']
  end

  def test_review_without_approval_extends_review_to_merge
    r = pr(3)
    assert_includes r['flags'], 'no_approval'
    assert_equal 4 * H, r['pickup_s']
    assert_equal 6 * H, r['review_s']
    assert_equal 0.0, r['merge_wait_s']
  end

  # rule 4
  def test_bot_reviews_and_comments_never_count_as_response
    r = pr(4)
    assert_includes r['flags'], 'no_review' # author's own comment is not a response either
    assert_empty r['reviewers']
    assert_equal 8 * H, r['pickup_s']
  end

  # rule 5
  def test_approval_after_merge_falls_back_instead_of_going_negative
    r = pr(5)
    assert_includes r['flags'], 'approval_after_merge'
    assert_equal 2 * H, r['pickup_s']
    assert_equal 4 * H, r['review_s']
    assert_equal 0.0, r['merge_wait_s']
  end

  def test_clock_skew_clamps_to_nil_and_is_flagged
    r = pr(7)
    assert_includes r['flags'], 'clamped_negative'
    assert_nil r['total_s']
    assert_nil r['pickup_s']
  end

  def test_force_push_flagged_but_still_measured
    r = pr(6)
    assert_includes r['flags'], 'force_pushed'
    assert_equal 12 * H, r['pickup_s'] # a lone approval is both first response and approval
    assert_equal 0.0, r['review_s']
    assert_equal 12 * H, r['merge_wait_s']
  end

  # rules 7 and 9
  def test_open_and_ignored_prs_excluded
    refute_includes @rows.map { |r| r['number'] }, 8
    refute_includes @rows.map { |r| r['number'] }, 9
  end

  # rule 6
  def test_zero_is_not_nil
    assert_equal 0.0, pr(2)['merge_wait_s']
    assert_nil pr(2)['first_response_at']
  end

  # rule 8
  def test_small_n_suppressed
    b = Aggregate.summarize('w', @rows)
    assert b['suppressed'], 'fewer than 10 scored PRs must suppress'
    assert_equal 1, b['clamped']
  end

  def test_bottleneck_is_the_biggest_median_stage
    assert_equal 'pickup', Aggregate.summarize('w', @rows)['bottleneck']
  end

  def test_filters_compose_with_and
    assert_equal [1], Aggregate.filter(@rows, label: %w[backend], author: %w[alice]).map { |r| r['number'] }
    assert_equal [6], Aggregate.filter(@rows, min_size: 500).map { |r| r['number'] }
    assert_equal [1, 5], Aggregate.filter(@rows, reviewer: %w[bob], author: %w[alice]).map { |r| r['number'] }
  end
end
