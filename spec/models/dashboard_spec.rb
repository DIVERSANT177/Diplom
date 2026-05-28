require "rails_helper"

RSpec.describe Dashboard, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:cases).dependent(:destroy) }
    it { is_expected.to have_many(:gene_expressions).dependent(:destroy) }
    it { is_expected.to have_many(:analyses).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:dashboard) }

    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_inclusion_of(:status).in_array(Dashboard::STATUSES) }
    it { is_expected.to validate_inclusion_of(:survival_endpoint).in_array(Dashboard::ENDPOINTS) }

    it "is invalid without a user" do
      dashboard = build(:dashboard, user: nil)
      expect(dashboard).not_to be_valid
    end

    it "rejects an unknown status" do
      dashboard = build(:dashboard, status: "exploded")
      expect(dashboard).not_to be_valid
      expect(dashboard.errors[:status]).to be_present
    end
  end

  describe "constants" do
    it "defines the allowed statuses" do
      expect(Dashboard::STATUSES).to eq(%w[draft fetching ready error])
    end

    it "defines the allowed endpoints" do
      expect(Dashboard::ENDPOINTS).to eq(%w[OS])
    end

    it "defines the allowed visualizations" do
      expect(Dashboard::VISUALIZATIONS).to eq(%w[kaplan_meier heatmap clinical_summary])
    end
  end

  describe "defaults from the database" do
    it "starts as draft with default values" do
      dashboard = described_class.new(title: "t", user: create(:user))
      expect(dashboard.status).to eq("draft")
      expect(dashboard.projects).to eq([])
      expect(dashboard.visualizations).to eq([])
      expect(dashboard.survival_endpoint).to eq("OS")
      expect(dashboard.top_genes_count).to eq(50)
      expect(dashboard.expression_status).to eq("pending")
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }

    describe ".recent" do
      it "orders by updated_at desc" do
        old = create(:dashboard, user: user, updated_at: 2.days.ago)
        mid = create(:dashboard, user: user, updated_at: 1.day.ago)
        fresh = create(:dashboard, user: user, updated_at: Time.current)

        expect(described_class.recent).to eq([ fresh, mid, old ])
      end
    end

    describe ".ready" do
      it "returns only dashboards with status ready" do
        ready = create(:dashboard, :ready, user: user)
        create(:dashboard, user: user, status: "draft")
        create(:dashboard, :fetching, user: user)

        expect(described_class.ready).to eq([ ready ])
      end
    end
  end

  describe ".visualization_label" do
    it "returns the localized label for a known visualization" do
      expect(Dashboard.visualization_label("heatmap"))
        .to eq(I18n.t("dashboards.visualizations.heatmap"))
    end
  end

end
