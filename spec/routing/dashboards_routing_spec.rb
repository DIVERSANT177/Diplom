require "rails_helper"

RSpec.describe DashboardsController, type: :routing do
  describe "routing" do
    it "routes GET /dashboards to #index" do
      expect(get: "/dashboards").to route_to("dashboards#index")
    end

    it "routes GET /dashboards/new to #new" do
      expect(get: "/dashboards/new").to route_to("dashboards#new")
    end

    it "routes GET /dashboards/:id to #show" do
      expect(get: "/dashboards/42").to route_to("dashboards#show", id: "42")
    end

    it "routes GET /dashboards/:id/edit to #edit" do
      expect(get: "/dashboards/42/edit").to route_to("dashboards#edit", id: "42")
    end

    it "routes POST /dashboards to #create" do
      expect(post: "/dashboards").to route_to("dashboards#create")
    end

    it "routes PATCH /dashboards/:id to #update" do
      expect(patch: "/dashboards/42").to route_to("dashboards#update", id: "42")
    end

    it "routes PUT /dashboards/:id to #update" do
      expect(put: "/dashboards/42").to route_to("dashboards#update", id: "42")
    end

    it "routes DELETE /dashboards/:id to #destroy" do
      expect(delete: "/dashboards/42").to route_to("dashboards#destroy", id: "42")
    end

    it "routes GET /dashboards/:id/heatmap_data to #heatmap_data" do
      expect(get: "/dashboards/42/heatmap_data").to route_to("dashboards#heatmap_data", id: "42")
    end
  end
end

RSpec.describe "Devise routes", type: :routing do
  it "routes the root path to the login page" do
    expect(get: "/").to route_to("devise/sessions#new")
  end

  it "routes GET /users/sign_in to sessions#new" do
    expect(get: "/users/sign_in").to route_to("devise/sessions#new")
  end

  it "routes POST /users/sign_in to sessions#create" do
    expect(post: "/users/sign_in").to route_to("devise/sessions#create")
  end

  it "routes DELETE /users/sign_out to sessions#destroy" do
    expect(delete: "/users/sign_out").to route_to("devise/sessions#destroy")
  end

  it "routes GET /users/sign_up to registrations#new" do
    expect(get: "/users/sign_up").to route_to("devise/registrations#new")
  end

  it "routes POST /users to registrations#create" do
    expect(post: "/users").to route_to("devise/registrations#create")
  end
end
