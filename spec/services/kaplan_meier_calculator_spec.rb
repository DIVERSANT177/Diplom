require "rails_helper"

RSpec.describe KaplanMeierCalculator do
  let(:user)      { create(:user) }
  let(:dashboard) { create(:dashboard, :ready, user: user) }

  def make_case(vital:, days:, gender: "female")
    if vital == "Dead"
      create(:patient_case,
             dashboard: dashboard,
             vital_status: "Dead",
             days_to_death: days&.to_f,
             days_to_last_follow_up: nil,
             gender: gender)
    else
      create(:patient_case,
             dashboard: dashboard,
             vital_status: "Alive",
             days_to_death: nil,
             days_to_last_follow_up: days&.to_f,
             gender: gender)
    end
  end

  describe "#call" do
    context "without stratification" do
      it "groups all cases under one bucket starting at S=1" do
        cases = [
          make_case(vital: "Alive", days: 1000),
          make_case(vital: "Dead",  days: 500)
        ]

        result = described_class.new(cases).call

        expect(result.keys).to eq([ "Все пациенты" ])
        curve = result["Все пациенты"]
        expect(curve.first).to eq({ time: 0, survival: 1.0 })
      end

      it "produces a non-increasing curve when there are deaths" do
        cases = [
          make_case(vital: "Dead",  days: 100),
          make_case(vital: "Dead",  days: 200),
          make_case(vital: "Alive", days: 300)
        ]

        curve = described_class.new(cases).call["Все пациенты"]
        survivals = curve.map { |pt| pt[:survival] }

        expect(survivals.first).to eq(1.0)
        expect(survivals).to eq(survivals.sort.reverse)
        expect(survivals.last).to be < 1.0
      end

      it "remains at 1.0 when no deaths occur" do
        cases = Array.new(3) { make_case(vital: "Alive", days: 500) }
        curve = described_class.new(cases).call["Все пациенты"]

        expect(curve.map { |pt| pt[:survival] }.uniq).to eq([ 1.0 ])
      end

      it "drops to zero when a single observation dies" do
        cases = [ make_case(vital: "Dead", days: 100) ]
        curve = described_class.new(cases).call["Все пациенты"]

        expect(curve.last[:time]).to eq(100)
        expect(curve.last[:survival]).to eq(0.0)
      end
    end

    context "with stratification" do
      it "splits curves by the chosen attribute" do
        females = Array.new(2) { make_case(vital: "Alive", days: 500, gender: "female") }
        males   = [
          make_case(vital: "Dead",  days: 200, gender: "male"),
          make_case(vital: "Alive", days: 800, gender: "male")
        ]

        result = described_class.new(females + males, stratify_by: :gender).call

        expect(result.keys).to match_array(%w[female male])
        expect(result["female"].map { |pt| pt[:survival] }.uniq).to eq([ 1.0 ])
        expect(result["male"].last[:survival]).to be < 1.0
      end
    end

    context "with invalid time entries" do
      it "ignores nil and negative observation times" do
        valid    = make_case(vital: "Dead",  days: 100)
        negative = make_case(vital: "Dead",  days: -10)
        nil_time = make_case(vital: "Alive", days: nil)

        curve = described_class.new([ valid, negative, nil_time ]).call["Все пациенты"]

        # Only the single valid (Dead at 100) event should produce a step beyond t=0
        steps_after_zero = curve.drop(1)
        expect(steps_after_zero.size).to eq(1)
        expect(steps_after_zero.first[:time]).to eq(100)
      end
    end
  end
end
