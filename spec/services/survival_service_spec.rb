require "rails_helper"

RSpec.describe SurvivalService do
  let(:user)      { create(:user) }
  let(:dashboard) { create(:dashboard, :ready, user: user) }
  let(:top_genes) { %w[GENE1 GENE2 GENE3] }

  let(:analysis) do
    create(:analysis, :survival, :running,
           dashboard: dashboard,
           params: { "n_top_genes" => 3, "model_type" => "ridge", "reg_param" => 1.0 })
  end

  def seed_feature_importance(genes = top_genes)
    create(:analysis, :feature_importance_ready,
           dashboard: dashboard,
           result: { "top_genes" => genes.map { |g| { "gene" => g } } })
  end

  def seed_patient(idx, vital:, days:, age: 60, gender: "female", stage: "Stage II", expression: nil)
    case_id = "PT#{format('%04d', idx)}"

    if vital == "Dead"
      kase = create(:patient_case,
                    dashboard: dashboard, case_id: case_id,
                    vital_status: "Dead",
                    days_to_death: days.to_f,
                    days_to_last_follow_up: nil,
                    age_at_index: age, gender: gender, tumor_stage: stage)
    else
      kase = create(:patient_case,
                    dashboard: dashboard, case_id: case_id,
                    vital_status: "Alive",
                    days_to_death: nil,
                    days_to_last_follow_up: days.to_f,
                    age_at_index: age, gender: gender, tumor_stage: stage)
    end

    expression ||= top_genes.each_with_index.to_h { |g, i| [ g, 1.0 + i + (idx % 5) ] }
    expression.each do |gene, tpm|
      create(:gene_expression,
             dashboard: dashboard, case_id: case_id,
             gene_name: gene, gene_id: gene, tpm: tpm,
             project_id: "TCGA-BRCA")
    end

    kase
  end

  def seed_population(n_dead: 12, n_alive: 18)
    seed_feature_importance
    n_dead.times  { |i| seed_patient(i + 1,       vital: "Dead",  days: 100 + i * 25, age: 60 + (i % 5)) }
    n_alive.times { |i| seed_patient(100 + i + 1, vital: "Alive", days: 900 + i * 40, age: 50 + (i % 6)) }
  end

  describe "#call" do
    context "when no Feature Importance analysis is present" do
      before { seed_population }

      it "raises asking to run Feature Importance" do
        Analysis.where(algorithm: "feature_importance").destroy_all

        expect { described_class.new(analysis).call }
          .to raise_error(/Feature Importance/)
      end
    end

    context "with too few patients" do
      before { seed_population(n_dead: 2, n_alive: 5) }

      it "raises explaining the minimum cohort size" do
        expect { described_class.new(analysis).call }
          .to raise_error(/минимум/)
      end
    end

    context "with sufficient data and the ridge model" do
      before { seed_population }

      it "returns the expected top-level structure" do
        result = described_class.new(analysis).call

        expect(result).to include(
          "algorithm"  => "survival",
          "model_type" => "ridge",
          "n_cases"    => 30
        )
        expect(result["n_train"] + result["n_test"]).to eq(30)
        expect(result["n_train"]).to be > result["n_test"]
        expect(result["n_events_train"] + result["n_events_test"]).to eq(12)
      end

      it "produces a c-index between 0 and 1 on each split" do
        result = described_class.new(analysis).call

        [ result["c_index_train"], result["c_index_test"], result["c_index"] ].each do |c|
          next if c.nil?
          expect(c).to be_between(0.0, 1.0).inclusive
        end
      end

      it "builds a population KM curve that starts at S=1 and is non-increasing" do
        result = described_class.new(analysis).call
        curve  = result["survival_curve"]

        expect(curve).not_to be_empty
        expect(curve.first["time"]).to eq(0)
        expect(curve.first["survival"]).to eq(1.0)

        survivals = curve.map { |pt| pt["survival"] }
        survivals.each_cons(2) { |a, b| expect(a).to be >= b }
        expect(survivals.last).to be_between(0.0, 1.0).inclusive
      end

      it "lists feature names with age, sex, all stages and gene columns" do
        result = described_class.new(analysis).call

        expect(result["feature_names"]).to eq(
          [ "age_normalized", "is_male",
            "stage_i", "stage_ii", "stage_iii", "stage_iv",
            "gene:GENE1", "gene:GENE2", "gene:GENE3" ]
        )
      end

      it "produces one prediction row per patient with split labels" do
        result = described_class.new(analysis).call
        preds  = result["predictions"]

        expect(preds.size).to eq(30)
        expect(preds.map { |p| p["case_id"] }.uniq.size).to eq(30)
        expect(preds.map { |p| p["split"] }.uniq).to match_array(%w[train test])

        preds.each do |row|
          expect(row).to include("case_id", "split", "predicted_days",
                                 "actual_days", "vital_status")
          expect(row["predicted_days"]).to be_a(Numeric)
          expect(row["predicted_days"]).to be > 0
        end
      end

      it "returns coefficients ordered by absolute standardized impact" do
        result = described_class.new(analysis).call
        coefs  = result["coefficients"]

        expect(coefs.size).to eq(result["feature_names"].size)
        coefs.each do |c|
          expect(c).to include("feature", "coefficient", "standardized_coefficient",
                               "feature_std", "direction")
          expect(%w[protective risk]).to include(c["direction"])
          expect(c["hazard_ratio"]).to be_nil # ridge: no hazard ratio
        end

        abs_std = coefs.map { |c| c["standardized_coefficient"].abs }
        expect(abs_std).to eq(abs_std.sort.reverse)
      end

      it "stores normalization stats and gene order in artifacts" do
        result    = described_class.new(analysis).call
        artifacts = result["model_artifacts"]

        expect(artifacts).to include(
          "feature_scale" => "log1p_tpm",
          "gene_order"    => top_genes
        )
        expect(artifacts).to include("age_mean", "age_std", "gene_means",
                                      "gene_stds", "weights", "feature_order")
        expect(artifacts["gene_means"].keys).to match_array(top_genes)
      end
    end

    context "with the Cox model" do
      before do
        seed_population
        analysis.update!(params: { "n_top_genes" => 3, "model_type" => "cox", "reg_param" => 0.1 })
      end

      it "exposes hazard ratios on coefficients" do
        result = described_class.new(analysis).call

        expect(result["model_type"]).to eq("cox")
        result["coefficients"].each do |c|
          expect(c["hazard_ratio"]).to be_a(Numeric)
          expect(c["hazard_ratio"]).to be > 0
        end
      end

      it "stores a baseline survival curve in artifacts" do
        result   = described_class.new(analysis).call
        baseline = result["model_artifacts"]["baseline_survival"]

        expect(baseline).to be_an(Array)
        expect(baseline.first).to include("time" => 0.0, "s0" => 1.0)
        s0_values = baseline.map { |pt| pt["s0"] }
        s0_values.each_cons(2) { |a, b| expect(a).to be >= b }
        expect(s0_values.last).to be_between(0.0, 1.0).inclusive
      end

      it "tracks training info with convergence metadata" do
        result = described_class.new(analysis).call
        info   = result["training_info"]

        expect(info["type"]).to eq("cox")
        expect(info).to have_key("converged")
        expect(info["n_iter"]).to be_a(Integer)
        expect(info["n_iter"]).to be > 0
        expect(info["reg_param"]).to eq(0.1)
      end
    end

    context "when a clustering analysis is available" do
      before do
        seed_population

        cases = Case.where(dashboard: dashboard).order(:case_id)
        clusters = cases.each_with_index.map { |c, i| { "case_id" => c.case_id, "cluster" => i % 2 } }

        create(:analysis, :ready,
               dashboard: dashboard,
               algorithm: "clustering",
               result: { "patient_clusters" => clusters })
      end

      it "builds per-cluster KM curves keyed by cluster id" do
        result = described_class.new(analysis).call
        curves = result["cluster_curves"]

        expect(curves).not_to be_empty
        expect(curves.keys).to match_array(%w[0 1])
        curves.each_value do |c|
          expect(c.first["time"]).to eq(0)
          expect(c.first["survival"]).to eq(1.0)
        end
      end

      it "annotates each prediction with its cluster id" do
        result = described_class.new(analysis).call

        clusters = result["predictions"].map { |p| p["cluster"] }.compact.uniq
        expect(clusters).to match_array([ 0, 1 ])
      end
    end

    context "when no clustering analysis exists" do
      before { seed_population }

      it "returns an empty cluster_curves hash" do
        result = described_class.new(analysis).call
        expect(result["cluster_curves"]).to eq({})
      end
    end
  end

  describe ".normalize_stage" do
    it "maps GDC strings and form values to a stable set of codes" do
      expect(described_class.normalize_stage("Stage IV")).to  eq("stage_iv")
      expect(described_class.normalize_stage("stage iii")).to eq("stage_iii")
      expect(described_class.normalize_stage("Stage IIA")).to eq("stage_ii")
      expect(described_class.normalize_stage("stage_i")).to   eq("stage_i")
      expect(described_class.normalize_stage("not reported")).to eq("unknown")
      expect(described_class.normalize_stage(nil)).to        eq("unknown")
    end
  end
end
