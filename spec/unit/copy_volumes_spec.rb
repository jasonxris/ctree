# frozen_string_literal: true

RSpec.describe "Ctree::Create.copy_volumes" do
  let(:copy_targets) { [%w[src_a tgt_a], %w[src_b tgt_b], %w[src_c tgt_c]] }

  it "reports progress all the way to 100 as copies complete" do
    percents = []
    percents_mutex = Mutex.new
    allow(Ctree::Volume).to receive(:copy).and_return([fake_status(true), "", 1024])

    Ctree::Create.copy_volumes(copy_targets, Thread::SizedQueue.new(2),
                               ->(percent) { percents_mutex.synchronize { percents << percent } })

    expect(percents.max).to eq(100)
  end

  it "returns each copy's outcome in registration order regardless of finishing order" do
    allow(Ctree::Volume).to receive(:copy) do |src_vol, _tgt_vol|
      sleep 0.05 if src_vol == "src_a"
      [fake_status(true), "", src_vol]
    end

    outcomes = Ctree::Create.copy_volumes(copy_targets, Thread::SizedQueue.new(3), ->(_percent) {})

    expect(outcomes.map(&:last)).to eq(%w[src_a src_b src_c])
  end

  it "holds no more than the semaphore's permits at once" do
    in_flight = 0
    peak = 0
    tracker = Mutex.new
    allow(Ctree::Volume).to receive(:copy) do
      tracker.synchronize { in_flight += 1; peak = [peak, in_flight].max }
      sleep 0.05
      tracker.synchronize { in_flight -= 1 }
      [fake_status(true), "", 1024]
    end

    Ctree::Create.copy_volumes(copy_targets, Thread::SizedQueue.new(2), ->(_percent) {})

    expect(peak).to eq(2)
  end
end
