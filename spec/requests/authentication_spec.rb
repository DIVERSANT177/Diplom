require "rails_helper"

RSpec.describe "Authentication", type: :request do
  describe "GET /" do
    it "renders the sign-in page as the root for anonymous users" do
      get "/"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("devise.sessions.new.title"))
    end
  end

  describe "access control for protected controllers" do
    it "redirects unauthenticated requests to /dashboards to the login page" do
      get dashboards_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "redirects unauthenticated requests to /dashboards/new to the login page" do
      get new_dashboard_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "does not require authentication for the locale switch endpoint" do
      post switch_locale_path, params: { locale: "en" }
      expect(response).to redirect_to(root_path)
      expect(response).not_to redirect_to(new_user_session_path)
    end
  end
end

RSpec.describe "Registration", type: :request do
  describe "GET /users/sign_up" do
    it "renders the sign-up form" do
      get new_user_registration_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("devise.registrations.new.title"))
    end
  end

  describe "POST /users" do
    let(:valid_params) do
      {
        user: {
          email: "new_user@example.com",
          password: "password123",
          password_confirmation: "password123"
        }
      }
    end

    it "creates a new user with valid parameters" do
      expect { post user_registration_path, params: valid_params }
        .to change { User.count }.by(1)
    end

    it "signs in the user after successful registration" do
      post user_registration_path, params: valid_params
      expect(response).to redirect_to(dashboards_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it "does not create a user when email is missing" do
      invalid = valid_params.deep_dup
      invalid[:user][:email] = ""

      expect { post user_registration_path, params: invalid }
        .not_to change { User.count }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "does not create a user when passwords don't match" do
      invalid = valid_params.deep_dup
      invalid[:user][:password_confirmation] = "different"

      expect { post user_registration_path, params: invalid }
        .not_to change { User.count }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "does not create a user when email is already taken" do
      create(:user, email: "taken@example.com")
      params = valid_params.deep_dup
      params[:user][:email] = "taken@example.com"

      expect { post user_registration_path, params: params }
        .not_to change { User.count }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end

RSpec.describe "Session", type: :request do
  describe "GET /users/sign_in" do
    it "renders the sign-in form" do
      get new_user_session_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("devise.sessions.new.title"))
    end
  end

  describe "POST /users/sign_in" do
    let!(:user) { create(:user, email: "login@example.com", password: "password123", password_confirmation: "password123") }

    it "signs in the user with correct credentials and redirects to dashboards" do
      post user_session_path, params: { user: { email: user.email, password: "password123" } }
      expect(response).to redirect_to(dashboards_path)
    end

    it "rejects invalid credentials" do
      post user_session_path, params: { user: { email: user.email, password: "wrong-password" } }
      expect(response).to have_http_status(:unprocessable_entity).or have_http_status(:ok)
      expect(response.body).not_to match(/signed in/i)
    end

    it "rejects sign-in for unknown email" do
      post user_session_path, params: { user: { email: "ghost@example.com", password: "password123" } }
      expect(response).to have_http_status(:unprocessable_entity).or have_http_status(:ok)
    end
  end

  describe "DELETE /users/sign_out" do
    let(:user) { create(:user) }

    it "signs out an authenticated user" do
      sign_in user
      get dashboards_path
      expect(response).to have_http_status(:ok)

      delete destroy_user_session_path
      expect(response).to redirect_to(root_path)

      get dashboards_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
