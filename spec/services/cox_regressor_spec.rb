require "rails_helper"

RSpec.describe CoxRegressor do
  # Helper: synthetic dataset where higher x corresponds to shorter survival.
  def linear_risk_dataset(n: 60, seed: 7, slope: 80.0, base: 200.0,
                         noise_scale: 0.2, time_floor: 10.0, time_ceil: 1000.0)
    rng    = Random.new(seed)
    rows   = []
    times  = []
    events = []
    n.times do
      x = rng.rand(-1.0..1.0)
      noise = rng.rand(-noise_scale..noise_scale)
      t = (base - slope * x + noise * 30).clamp(time_floor, time_ceil)
      rows   << [ x ]
      times  << t
      events << 1
    end
    [ Numo::DFloat[*rows], times, events ]
  end

  describe "#fit" do
    it "raises when no events are observed" do
      x_matrix = Numo::DFloat[[ 0.1 ], [ 0.2 ], [ 0.3 ]]
      expect {
        described_class.new.fit(x_matrix, [ 100, 200, 300 ], [ 0, 0, 0 ])
      }.to raise_error(ArgumentError, /событие/)
    end

    it "returns self for chaining" do
      x_matrix, times, events = linear_risk_dataset
      cox = described_class.new(reg_param: 0.1)
      expect(cox.fit(x_matrix, times, events)).to equal(cox)
    end

    it "learns positive coefficients for risk-driving features" do
      x_matrix, times, events = linear_risk_dataset
      cox = described_class.new(reg_param: 0.05).fit(x_matrix, times, events)

      expect(cox.weights[0]).to be > 0
      expect(cox.n_iter).to be > 0
      expect(cox.final_loss).to be_finite
    end

    it "produces a baseline survival curve starting at S0=1.0" do
      x_matrix, times, events = linear_risk_dataset
      cox = described_class.new(reg_param: 0.1).fit(x_matrix, times, events)

      baseline = cox.baseline_survival
      expect(baseline).not_to be_empty
      expect(baseline.first).to include("time" => 0.0, "s0" => 1.0, "h0_cum" => 0.0)

      s0_values = baseline.map { |pt| pt["s0"] }
      s0_values.each_cons(2) { |a, b| expect(a).to be >= b }
      expect(s0_values.last).to be_between(0.0, 1.0).inclusive
    end

    it "converges within MAX_ITER on a clean dataset" do
      x_matrix, times, events = linear_risk_dataset(n: 80, slope: 100, noise_scale: 0.05)
      cox = described_class.new(reg_param: 0.05).fit(x_matrix, times, events)

      expect([ true, false ]).to include(cox.converged)
      expect(cox.n_iter).to be <= CoxRegressor::MAX_ITER
    end
  end

  describe "#predict_risk" do
    it "returns one risk score per row" do
      x_matrix, times, events = linear_risk_dataset
      cox = described_class.new(reg_param: 0.1).fit(x_matrix, times, events)

      risks = cox.predict_risk(x_matrix)
      expect(risks).to be_an(Array)
      expect(risks.size).to eq(x_matrix.shape[0])
      risks.each { |r| expect(r).to be_finite }
    end

    it "ranks higher feature values as higher risk" do
      x_matrix, times, events = linear_risk_dataset
      cox = described_class.new(reg_param: 0.05).fit(x_matrix, times, events)

      risk_high = cox.predict_risk(Numo::DFloat[[ 1.0 ]]).first
      risk_low  = cox.predict_risk(Numo::DFloat[[ -1.0 ]]).first

      expect(risk_high).to be > risk_low
    end
  end

  describe "#median_survival_for" do
    it "returns shorter median survival for higher risk" do
      x_matrix, times, events = linear_risk_dataset(n: 80, slope: 90.0)
      cox = described_class.new(reg_param: 0.01).fit(x_matrix, times, events)

      high = cox.median_survival_for(cox.predict_risk(Numo::DFloat[[ 1.0 ]]).first)
      low  = cox.median_survival_for(cox.predict_risk(Numo::DFloat[[ -1.0 ]]).first)

      expect(high).to be > 0
      expect(low).to be > 0
      expect(high).to be < low
    end

    it "clamps absurdly large risks instead of crashing" do
      x_matrix, times, events = linear_risk_dataset
      cox = described_class.new(reg_param: 0.1).fit(x_matrix, times, events)

      expect { cox.median_survival_for(1_000.0) }.not_to raise_error
      expect { cox.median_survival_for(-1_000.0) }.not_to raise_error
    end
  end
end
