require "rails_helper"

RSpec.describe "Dashboards", type: :system do
  let(:user) { create(:user) }

  before do
    stub_gdc_projects
    sign_in user
  end

  it "shows the empty state for a user with no dashboards" do
    visit dashboards_path
    expect(page).to have_content(I18n.t("dashboards.index.empty"))
    expect(page).to have_link(I18n.t("dashboards.index.new_button"))
  end

  it "lists existing dashboards owned by the user" do
    create(:dashboard, user: user, title: "Breast cancer analysis")
    create(:dashboard, user: user, title: "Lung cancer analysis")

    visit dashboards_path
    expect(page).to have_content("Breast cancer analysis")
    expect(page).to have_content("Lung cancer analysis")
  end

  it "does not list dashboards owned by other users" do
    other = create(:user)
    create(:dashboard, user: other, title: "Someone else's dashboard")

    visit dashboards_path
    expect(page).not_to have_content("Someone else's dashboard")
  end

  it "creates a new dashboard via the form" do
    visit new_dashboard_path

    fill_in "dashboard_title", with: "My new dashboard"
    check "dashboard_projects_TCGA-BRCA"
    click_button I18n.t("helpers.submit.dashboard.create")

    created = Dashboard.order(:created_at).last
    expect(created.title).to eq("My new dashboard")
    expect(created.projects).to include("TCGA-BRCA")
    expect(created.user).to eq(user)
    expect(page).to have_current_path(dashboard_path(created))
  end

  it "shows validation errors when title is blank" do
    visit new_dashboard_path
    click_button I18n.t("helpers.submit.dashboard.create")

    expect(page).to have_css(".alert-danger")
    expect(Dashboard.count).to eq(0)
  end

  it "lets the user edit an existing dashboard" do
    dashboard = create(:dashboard, user: user, title: "Old title")

    visit edit_dashboard_path(dashboard)
    fill_in "dashboard_title", with: "New title"
    click_button I18n.t("helpers.submit.dashboard.update")

    expect(dashboard.reload.title).to eq("New title")
  end

  it "lets the user destroy a dashboard" do
    dashboard = create(:dashboard, user: user, title: "Delete me")

    visit dashboards_path
    expect { click_button I18n.t("dashboards.index.delete") }
      .to change { Dashboard.count }.by(-1)
    expect(Dashboard.exists?(dashboard.id)).to be false
  end
end
