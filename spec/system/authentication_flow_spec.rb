require "rails_helper"

RSpec.describe "Authentication flow", type: :system do
  before { stub_gdc_projects }

  it "allows a user to register and then lands on the empty dashboard index" do
    visit new_user_registration_path

    fill_in "user_email", with: "first-user@example.com"
    fill_in "user_password", with: "password123"
    fill_in "user_password_confirmation", with: "password123"
    click_button I18n.t("devise.registrations.new.submit")

    expect(page).to have_current_path(dashboards_path)
    expect(page).to have_content(I18n.t("dashboards.index.empty"))
  end

  it "lets a returning user sign in" do
    user = create(:user, email: "returning@example.com", password: "password123", password_confirmation: "password123")

    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button I18n.t("devise.sessions.new.submit")

    expect(page).to have_current_path(dashboards_path)
  end

  it "rejects sign in with wrong password and keeps user unauthenticated" do
    create(:user, email: "known@example.com", password: "password123", password_confirmation: "password123")

    visit new_user_session_path
    fill_in "user_email", with: "known@example.com"
    fill_in "user_password", with: "wrong-password"
    click_button I18n.t("devise.sessions.new.submit")

    visit dashboards_path
    expect(page).to have_current_path(new_user_session_path)
  end
end
