class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # before_action :authenticate_user!, unless: :devise_controller?
  before_action :set_locale

  allow_browser versions: :modern

  def set_locale
    I18n.locale = session[:locale] || I18n.default_locale
  end


  protected

  def after_sign_in_path_for(resource)
    dashboards_path  # Перенаправит на /dashboard после логина
  end
end
