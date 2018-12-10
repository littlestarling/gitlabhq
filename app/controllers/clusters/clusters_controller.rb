# frozen_string_literal: true

class Clusters::ClustersController < Clusters::BaseController
  include RoutableActions

  before_action :cluster, except: [:index, :new, :create_gcp, :create_user]
  before_action :generate_gcp_authorize_url, only: [:new]
  before_action :validate_gcp_token, only: [:new]
  before_action :gcp_cluster, only: [:new]
  before_action :user_cluster, only: [:new]
  before_action :authorize_create_cluster!, only: [:new]
  before_action :authorize_update_cluster!, only: [:update]
  before_action :authorize_admin_cluster!, only: [:destroy]
  before_action :update_applications_status, only: [:cluster_status]

  helper_method :token_in_session

  STATUS_POLLING_INTERVAL = 10_000

  def index
    clusters = ClustersFinder.new(clusterable, current_user, :all).execute
    @clusters = clusters.page(params[:page]).per(20)
  end

  def new
  end

  # Overridding ActionController::Metal#status is NOT a good idea
  def cluster_status
    respond_to do |format|
      format.json do
        Gitlab::PollingInterval.set_header(response, interval: STATUS_POLLING_INTERVAL)

        render json: ClusterSerializer
          .new(current_user: @current_user)
          .represent_status(@cluster)
      end
    end
  end

  def show
  end

  def update
    Clusters::UpdateService
      .new(current_user, update_params)
      .execute(cluster)

    if cluster.valid?
      respond_to do |format|
        format.json do
          head :no_content
        end
        format.html do
          flash[:notice] = _('Kubernetes cluster was successfully updated.')
          redirect_to cluster.show_path
        end
      end
    else
      respond_to do |format|
        format.json { head :bad_request }
        format.html { render :show }
      end
    end
  end

  def destroy
    if cluster.destroy
      flash[:notice] = _('Kubernetes cluster integration was successfully removed.')
      redirect_to clusterable.index_path, status: :found
    else
      flash[:notice] = _('Kubernetes cluster integration was not removed.')
      render :show
    end
  end

  def create_gcp
    @gcp_cluster = ::Clusters::CreateService
      .new(current_user, create_gcp_cluster_params)
      .execute(access_token: token_in_session)
      .present(current_user: current_user)

    if @gcp_cluster.persisted?
      redirect_to @gcp_cluster.show_path
    else
      generate_gcp_authorize_url
      validate_gcp_token
      user_cluster

      render :new, locals: { active_tab: 'gcp' }
    end
  end

  def create_user
    @user_cluster = ::Clusters::CreateService
      .new(current_user, create_user_cluster_params)
      .execute(access_token: token_in_session)
      .present(current_user: current_user)

    if @user_cluster.persisted?
      redirect_to @user_cluster.show_path
    else
      generate_gcp_authorize_url
      validate_gcp_token
      gcp_cluster

      render :new, locals: { active_tab: 'user' }
    end
  end

  private

  def update_params
    if cluster.managed?
      params.require(:cluster).permit(
        :enabled,
        :environment_scope,
        platform_kubernetes_attributes: [
          :namespace
        ]
      )
    else
      params.require(:cluster).permit(
        :enabled,
        :name,
        :environment_scope,
        platform_kubernetes_attributes: [
          :api_url,
          :token,
          :ca_cert,
          :namespace
        ]
      )
    end
  end

  def create_gcp_cluster_params
    params.require(:cluster).permit(
      :enabled,
      :name,
      :environment_scope,
      provider_gcp_attributes: [
        :gcp_project_id,
        :zone,
        :num_nodes,
        :machine_type,
        :legacy_abac
      ]).merge(
        provider_type: :gcp,
        platform_type: :kubernetes,
        clusterable: clusterable.subject
      )
  end

  def create_user_cluster_params
    params.require(:cluster).permit(
      :enabled,
      :name,
      :environment_scope,
      platform_kubernetes_attributes: [
        :namespace,
        :api_url,
        :token,
        :ca_cert,
        :authorization_type
      ]).merge(
        provider_type: :user,
        platform_type: :kubernetes,
        clusterable: clusterable.subject
      )
  end

  def generate_gcp_authorize_url
    state = generate_session_key_redirect(clusterable.new_path.to_s)

    @authorize_url = GoogleApi::CloudPlatform::Client.new(
      nil, callback_google_api_auth_url,
      state: state).authorize_url
  rescue GoogleApi::Auth::ConfigMissingError
    # no-op
  end

  def gcp_cluster
    @gcp_cluster = new_cluster do |cluster|
      cluster.build_provider_gcp
    end
  end

  def user_cluster
    @user_cluster = new_cluster do |cluster|
      cluster.build_platform_kubernetes
    end
  end

  def new_cluster
    ::Clusters::Cluster.new.tap do |cluster|
      yield cluster

      case clusterable.subject
      when ::Project
        cluster.cluster_type = :project_type
      when ::Group
        cluster.cluster_type = :group_type
      else
        raise NotImplementedError
      end
    end.present(current_user: current_user)
  end

  def validate_gcp_token
    @valid_gcp_token = GoogleApi::CloudPlatform::Client.new(token_in_session, nil)
      .validate_token(expires_at_in_session)
  end

  def token_in_session
    session[GoogleApi::CloudPlatform::Client.session_key_for_token]
  end

  def expires_at_in_session
    @expires_at_in_session ||=
      session[GoogleApi::CloudPlatform::Client.session_key_for_expires_at]
  end

  def generate_session_key_redirect(uri)
    GoogleApi::CloudPlatform::Client.new_session_key_for_redirect_uri do |key|
      session[key] = uri
    end
  end

  def update_applications_status
    @cluster.applications.each(&:schedule_status_update)
  end
end
