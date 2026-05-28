require "rails_helper"

RSpec.describe "Dashboards", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  before { stub_gdc_projects }

  describe "authentication" do
    it "redirects all actions to the login page when signed out" do
      dashboard = create(:dashboard, user: user)

      [
        [ :get,    dashboards_path ],
        [ :get,    new_dashboard_path ],
        [ :get,    dashboard_path(dashboard) ],
        [ :get,    edit_dashboard_path(dashboard) ],
        [ :post,   dashboards_path ],
        [ :patch,  dashboard_path(dashboard) ],
        [ :delete, dashboard_path(dashboard) ]
      ].each do |verb, path|
        public_send(verb, path)
        expect(response).to redirect_to(new_user_session_path),
          "expected #{verb.upcase} #{path} to redirect to login, got #{response.status}"
      end
    end
  end

  context "as a signed-in user" do
    before { sign_in user }

    describe "GET /dashboards" do
      it "returns a successful response" do
        get dashboards_path
        expect(response).to have_http_status(:ok)
      end

      it "renders only dashboards owned by the current user" do
        create(:dashboard, user: user, title: "Mine")
        create(:dashboard, user: other_user, title: "Theirs")

        get dashboards_path
        expect(response.body).to include("Mine")
        expect(response.body).not_to include("Theirs")
      end

      it "shows the empty state when the user has no dashboards" do
        get dashboards_path
        expect(response.body).to include(I18n.t("dashboards.index.empty"))
      end

      it "responds with JSON when requested" do
        create(:dashboard, user: user)
        get dashboards_path, headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("application/json")
      end
    end

    describe "GET /dashboards/new" do
      it "renders the form" do
        get new_dashboard_path
        expect(response).to have_http_status(:ok)
      end

      it "loads the TCGA project list from GdcClient" do
        expect_any_instance_of(GdcClient).to receive(:projects).and_return(GdcClientStub::DEFAULT_PROJECTS)
        get new_dashboard_path
        expect(response.body).to include("TCGA-BRCA")
      end
    end

    describe "POST /dashboards" do
      let(:valid_params) do
        {
          dashboard: {
            title: "New analysis",
            survival_endpoint: "OS",
            top_genes_count: 50,
            projects: [ "TCGA-BRCA" ],
            visualizations: [ "clinical_summary" ]
          }
        }
      end

      it "creates a new dashboard tied to the current user" do
        expect { post dashboards_path, params: valid_params }
          .to change { user.dashboards.count }.by(1)

        expect(response).to redirect_to(Dashboard.last)
        expect(Dashboard.last.user).to eq(user)
      end

      it "enqueues the case import job after creating a dashboard" do
        expect {
          post dashboards_path, params: valid_params
        }.to have_enqueued_job(ImportCasesJob)
      end

      it "does not create a dashboard and re-renders the form when the title is missing" do
        invalid = valid_params.deep_dup
        invalid[:dashboard][:title] = ""

        expect { post dashboards_path, params: invalid }
          .not_to change { Dashboard.count }
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "permits only allowed parameters" do
        params = valid_params.deep_dup
        params[:dashboard][:user_id] = other_user.id
        params[:dashboard][:status] = "ready"

        post dashboards_path, params: params

        created = Dashboard.last
        expect(created.user).to eq(user)
        expect(created.status).to eq("draft")
      end
    end

    describe "GET /dashboards/:id" do
      it "renders the show page for a dashboard owned by the user" do
        dashboard = create(:dashboard, user: user)
        get dashboard_path(dashboard)
        expect(response).to have_http_status(:ok)
      end

      it "returns 404 when the dashboard belongs to another user" do
        other = create(:dashboard, user: other_user)
        get dashboard_path(other)
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for a missing dashboard id" do
        get dashboard_path(id: 999_999)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "GET /dashboards/:id/edit" do
      it "renders the edit form for an owned dashboard" do
        dashboard = create(:dashboard, user: user)
        get edit_dashboard_path(dashboard)
        expect(response).to have_http_status(:ok)
      end

      it "returns 404 when editing a dashboard owned by someone else" do
        other = create(:dashboard, user: other_user)
        get edit_dashboard_path(other)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "PATCH /dashboards/:id" do
      let!(:dashboard) { create(:dashboard, user: user, title: "Original") }

      it "updates an owned dashboard" do
        patch dashboard_path(dashboard), params: { dashboard: { title: "Updated" } }
        expect(dashboard.reload.title).to eq("Updated")
        expect(response).to redirect_to(dashboard)
      end

      it "returns a validation error when the title is blank (JSON)" do
        patch dashboard_path(dashboard),
              params: { dashboard: { title: "" } },
              as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(dashboard.reload.title).to eq("Original")
        expect(JSON.parse(response.body)).to have_key("title")
      end

      it "cannot update a dashboard owned by another user" do
        other = create(:dashboard, user: other_user, title: "NotMine")
        patch dashboard_path(other), params: { dashboard: { title: "Hacked" } }
        expect(response).to have_http_status(:not_found)
        expect(other.reload.title).to eq("NotMine")
      end
    end

    describe "DELETE /dashboards/:id" do
      it "destroys an owned dashboard" do
        dashboard = create(:dashboard, user: user)
        expect { delete dashboard_path(dashboard) }
          .to change { Dashboard.count }.by(-1)
        expect(response).to redirect_to(dashboards_path)
      end

      it "cannot destroy a dashboard owned by another user" do
        other = create(:dashboard, user: other_user)
        expect { delete dashboard_path(other) }.not_to change { Dashboard.count }
        expect(response).to have_http_status(:not_found)
        expect(Dashboard.exists?(other.id)).to be true
      end
    end

    describe "GET /dashboards/:id/heatmap_data" do
      let(:dashboard) { create(:dashboard, user: user) }

      it "returns 422 when expression data is not ready" do
        dashboard.update!(expression_status: "pending")
        get heatmap_data_dashboard_path(dashboard), headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to include("error" => "not_ready")
      end

      it "is not accessible for dashboards owned by another user" do
        other = create(:dashboard, user: other_user)
        get heatmap_data_dashboard_path(other)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
