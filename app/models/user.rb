# Gallery User model
class User < ActiveRecord::Base
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable,
         :confirmable, :omniauthable
  has_one :preference, dependent: :destroy
  has_one :user_summary, dependent: :destroy, autosave: true
  has_many :identities, dependent: :destroy
  has_many :environments, dependent: :destroy
  has_many :notebooks, as: :owner, dependent: :destroy
  has_many :notebooks_created, foreign_key: :creator_id, class_name: 'Notebook', dependent: :nullify
  # Note: notebooks_updated only returns notebooks where user is *most recent* updater
  has_many :notebooks_updated, foreign_key: :updater_id, class_name: 'Notebook', dependent: :nullify
  has_many :tags, dependent: :nullify
  has_many :change_requests, foreign_key: 'requestor_id', dependent: :destroy
  has_many :clicks, dependent: :destroy
  has_many :stages, dependent: :destroy
  has_many :user_similarities, dependent: :destroy
  has_many :suggested_groups, dependent: :destroy
  has_many :suggested_tags, dependent: :destroy
  has_many :suggested_notebooks, dependent: :destroy
  has_many :feedbacks, dependent: :nullify
  has_many :group_membership
  has_many :groups, through: :group_membership
  has_many :membership_owner, -> {where owner: true}, class_name: 'GroupMembership'
  has_many :groups_owner, through: :membership_owner, class_name: 'Group', source: :group
  has_many :membership_editor, -> {where editor: true}, class_name: 'GroupMembership'
  has_many :groups_editor, through: :membership_editor, class_name: 'Group', source: :group
  has_many :membership_creator, -> {where creator: true}, class_name: 'GroupMembership'
  has_many :groups_creator, through: :membership_creator, class_name: 'Group', source: :group
  has_and_belongs_to_many :shares, class_name: 'Notebook', join_table: 'shares'
  has_and_belongs_to_many :stars, class_name: 'Notebook', join_table: 'stars'
  has_many :executions

  validates :password, confirmation: true # two fields should match
  validates :email, uniqueness: { case_sensitive: false }, presence: true
  validates(
    :user_name,
    uniqueness: true,
    allow_nil: true,
    format: { with: /[a-zA-Z0-9\-_]+/ },
    exclusion: { in: %w[me] }
  )
  validates :email, email: true
  validate :email_in_allowed_domain

  extend Forwardable

  def email_in_allowed_domain
    allowed_domains = GalleryConfig.registration.allowed_domains
    allowed_domains&.each do |domain|
      errors.add(:email, "#{email} is not in the list of allowed domains") unless email.end_with? domain
    end
  end

  # Constructor
  def initialize(*args, &block)
    super(*args, &block)
    self.preference = Preference.new(easy_buttons: true)
    self.user_summary = UserSummary.new
  end

  # Make sure preference always exists
  def preference
    pref = super
    if pref
      pref
    else
      self.preference = Preference.new(easy_buttons: true)
    end
  end

  # Make sure summary always exists
  def user_summary
    summary = super
    if summary
      summary
    else
      self.user_summary = UserSummary.new
    end
  end

  # User's full name
  def name
    if last_name.blank? && first_name.blank?
      user_name
    elsif last_name.blank?
      first_name
    else
      "#{first_name} #{last_name}"
    end
  end

  include ExtendableModel

  #########################################################
  # Authentication stuff
  #########################################################

  # Is this a user with an account?
  # In practice this also means "logged in"
  def member?
    !id.nil?
  end

  # User needs to be logged in
  class NotAuthorized < RuntimeError
  end

  # User doesn't have permission
  class Forbidden < RuntimeError
  end

  # User didn't accept terms of service
  class MustAcceptTerms < RuntimeError
  end

  # User's profile is incomplete
  class MissingRequiredFields < RuntimeError
  end

  #########################################################
  # Group methods
  #########################################################

  # Return group-ids from the user's groups
  def group_gids
    groups.map(&:gid)
  end

  # Return whether the user is in the group with the given id
  def in_group?(group_or_gid)
    if group_or_gid.is_a?(Group)
      groups.include?(group_or_gid)
    else
      group_gids.include?(group_or_gid)
    end
  end

  # Return whether user owns a group
  def group_owner?(group_or_gid)
    if group_or_gid.is_a?(Group)
      groups_owner.include?(group_or_gid)
    else
      groups_owner.map(&:gid).include?(group_or_gid)
    end
  end

  # Return whether user can edit notebooks in a group
  def group_editor?(group_or_gid)
    if group_or_gid.is_a?(Group)
      groups_editor.include?(group_or_gid)
    else
      groups_editor.map(&:gid).include?(group_or_gid)
    end
  end

  # Returns an array of Groups that the user is a member of, and the number of notebooks in that group
  def groups_with_notebooks
    counts = Notebook.readable_by(self).where(owner: groups).group(:owner_id).count
    groups
      .map {|group| [group, counts.fetch(group.id, 0)]}
      .reject {|_group, count| count.zero?}
  end

  #########################################################
  # Notebook permission methods
  #########################################################

  # Return all notebooks the user can view
  def readable_notebooks(page=1)
    Notebook.paginate(page: page, per_page: @per_page).readable_by(self)
  end

  # Return all notebooks the user can edit
  def editable_notebooks(page=1)
    Notebook.paginate(page: page, per_page: @per_page).editable_by(self)
  end

  # Return whether user can edit the given notebook
  def can_edit?(notebook, use_admin=false)
    return false unless notebook.custom_edit_check(self, use_admin)
    notebook.owner == self ||
      groups_editor.include?(notebook.owner) ||
      shares.include?(notebook) ||
      (use_admin && admin?)
  end

  # Return whether user can view the given notebook
  def can_read?(notebook, use_admin=false)
    return false unless notebook.custom_read_check(self, use_admin)
    notebook.public ||
      can_edit?(notebook, use_admin) ||
      groups.include?(notebook.owner) ||
      (use_admin && admin?)
  end

  # Return whether the user can view the notebook ONLY because of admin
  def privileged_on?(notebook)
    admin? && !can_read?(notebook)
  end


  #########################################################
  # Notebook helpers
  #########################################################

  # Return viewable notebooks with a specific tag
  def readable_notebooks_with_tag(tag, page=1)
    readable_notebooks(page)
      .joins('LEFT OUTER JOIN tags ON tags.notebook_id = notebooks.id')
      .where('tags.tag = ?', tag)
  end

  # Return viewable notebooks with tag 'buildingblocks'
  def buildingblocks(page=1)
    readable_notebooks_with_tag('buildingblocks', page)
  end

  # Return viewable notebooks with tag 'trusted'
  def trusted(page=1)
    readable_notebooks_with_tag('trusted', page)
  end

  def change_requests_pending
    if member?
      ChangeRequest.where(notebook_id: Notebook.editable_by(self).pluck(:id), status: 'pending')
    else
      []
    end
  end

  def change_requests_owned
    if member?
      Notebook.editable_by(self).includes(:change_requests).flat_map(&:change_requests)
    else
      []
    end
  end

  #########################################################
  # Click helpers
  #########################################################

  # Delegate methods to summary object
  UserSummary.attribute_names.each do |name|
    next if name == 'id' || name.end_with?('_id', '_at')
    def_delegator :user_summary, name.to_sym, name.to_sym
  end

  def recent_updates
    clicks
      .includes(:notebook)
      .where(action: ['created notebook', 'updated notebook'])
      .order(updated_at: :desc)
  end

  def recent_actions
    clicks
      .includes(:notebook)
      .where.not(action: 'agreed to terms')
      .order(updated_at: :desc)
  end

  def users_of_notebooks(options={})
    # Number of users of this user's notebooks.  Get *all* public notebooks this
    # user has created, but restrict usage to the date range.
    min_date = options[:min_date]
    max_date = options[:max_date]
    notebook_ids = options[:notebook_ids] || notebooks_created.where(public: true).pluck(:id)
    return 0 if notebook_ids.blank?
    actions = ['ran notebook', 'downloaded notebook', 'executed notebook']
    users = Click.where(action: actions).where(notebook_id: notebook_ids)
    users = apply_date_range(users, min_date, max_date)
    users.select(:user_id).distinct.count
  end

  def notebook_execution_count(options={})
    # Count of unique notebooks with executions in the date range
    min_date = options[:min_date]
    max_date = options[:max_date]
    execs = apply_date_range(executions, min_date, max_date, 'executions.updated_at')
    execs.joins(:code_cell, :notebook).select('COUNT(DISTINCT notebooks.id) AS count').first.count
  end

  def health_bonus(notebook_ids)
    return 0 if notebook_ids.blank?
    NotebookSummary
      .where(notebook_id: notebook_ids)
      .pluck(:health)
      .select {|h| Notebook.health_symbol(h) == :healthy}
      .map {|h| 10.0 * h}
      .reduce(0, :+)
  end

  def notebook_action_counts(options={})
    # Start with counts of basic actions
    min_date = options[:min_date]
    max_date = options[:max_date]
    # Hash of action => count of unique notebooks, within the date range
    actions = apply_date_range(clicks, min_date, max_date, 'clicks.updated_at')
      .joins(:notebook)
      .select('action, COUNT(DISTINCT notebooks.id) AS count')
      .group(:action)
      .map {|e| [e.action, e.count]}
      .to_h
    # IDs of user's public created notebooks, ignoring date range
    all_public_ids = notebooks_created.where(public: true).pluck(:id)
    # Notebook objects of user's public created notebooks, within the date range
    public_nbs = apply_date_range(notebooks_created.where(public: true), min_date, max_date, 'created_at').all

    # Counts
    results = {
      view: actions['viewed notebook'] || 0,
      run: actions['ran notebook'] || 0,
      execute: actions['executed notebook'] || 0,
      download: actions['downloaded notebook'] || 0,
      create: actions['created notebook'] || 0,
      create_public: public_nbs.count,
      langs: public_nbs.map(&:lang).uniq.count,
      edit: actions['edited notebook'] || 0,
      users: users_of_notebooks(options.merge(notebook_ids: all_public_ids)),
      health_bonus: health_bonus(all_public_ids)
    }
    results[:edit_other] = apply_date_range(clicks, min_date, max_date, 'clicks.updated_at')
      .joins(:notebook)
      .where(action: 'edited notebook')
      .where('notebooks.creator_id != clicks.user_id')
      .select('notebooks.id')
      .distinct
      .count

    # TODO: we want to also log executions in clicks so we can remember them
    # when notebooks get updated.  For now, just get a count from executions,
    # knowing that the count might not be completely accurate.
    exec_count = notebook_execution_count(options)
    results[:execute] = [results[:execute], exec_count].max

    results
  end


  #########################################################
  # Recommendation helpers
  #########################################################

  def similar_users
    user_similarities
      .includes(:other_user)
      .order(score: :desc)
  end

  # Feature vector to compare with other users
  def feature_vector
    if @feature_vector.nil?
      @feature_vector =
        if clicks.loaded?
          # Save a database query if clicks are already loaded.
          # This reduces database load for UserSimilarity.compute_all
          # but seems to take about the same amount of time.
          clicks
            .select {|click| click.updated_at > 90.days.ago}
            .group_by(&:notebook_id)
            .map {|id, clicks| [id, clicks.size]}
            .to_h
        else
          clicks.where('updated_at > ?', 90.days.ago).group(:notebook_id).count
        end
      @feature_vector.each {|id, count| @feature_vector[id] = Math.log(count + 1)}
      stars.each do |star|
        @feature_vector[star.id] ||= 0
        @feature_vector[star.id] += 1
      end
    end
    @feature_vector
  end

  # Consider someone "new" if they haven't looked at many notebooks
  def newish_user
    feature_vector.size <= 3
  end

  # Compute recommendations for this user
  def compute_recommendations
    SuggestedNotebook.compute_for(self)
    SuggestedGroup.compute_for(self)
    SuggestedTag.compute_for(self)
  end

  # Recommended notebooks filtered by readability and deduped.
  # Not to be confused with #suggested_notebooks, which is a
  # direct join to the suggestion table without filter/dedupe.
  def notebook_recommendations(allow_run=true)
    # Compute on the fly in case the cron hasn't run for a new user
    compute_recommendations if allow_run && newish_user && suggested_notebooks.count.zero?

    # Return recommendations filtered for readability
    Notebook.readable_megajoin(self).order('score DESC').having('reasons IS NOT NULL')
  end

  # Recommended groups with number of readable notebooks
  def group_recommendations(allow_run=true)
    # Compute on the fly in case the cron hasn't run for a new user
    compute_recommendations if allow_run && newish_user && suggested_groups.count.zero?

    # Return hash of Group objects => number of readable notebooks
    suggested = Group.find(suggested_groups.pluck(:group_id))
    counts = Notebook.readable_by(self).where(owner: suggested).group(:owner_id).count
    suggested
      .map {|group| [group, counts.fetch(group.id, 0)]}
      .reject {|_group, count| count.zero?}
      .sort_by {|_group, count| -count + rand}
  end

  # Recommended tags with number of readable notebooks
  def tag_recommendations(allow_run=true)
    # Compute on the fly in case the cron hasn't run for a new user
    compute_recommendations if allow_run && newish_user && suggested_tags.count.zero?

    # Return hash of tag string => number of readable notebooks
    suggested = suggested_tags.pluck(:tag)
    counts = Notebook
      .readable_by(self)
      .joins('LEFT OUTER JOIN tags ON tags.notebook_id = notebooks.id')
      .where('tags.tag IN (?)', suggested)
      .group(:tag)
      .count
    suggested
      .map {|tag| [tag, counts.fetch(tag, 0)]}
      .reject {|_tag, count| count.zero?}
      .sort_by {|_tag, count| -count + rand}
  end

  def self.create_with_omniauth(info, _provider)
    user = {
      email: info['email'],
      password: Devise.friendly_token[0, 20],
      confirmed_at: Time.now.utc.to_datetime.to_s,
      confirmation_token: nil,
      first_name: info.first_name,
      last_name: info.last_name
    }
    create!(user)
  end

  def active_for_authentication?
    if GalleryConfig.registration.require_admin_approval
      super && approved?
    else
      super
    end
  end

  def inactive_message
    if !approved? && GalleryConfig.registration.require_admin_approval
      :not_approved
    else
      super
    end
  end

  #########################################################
  # Internal helpers
  #########################################################

  private

  def apply_date_range(relation, min_date=nil, max_date=nil, field='updated_at')
    relation = relation.where("#{field} >= ?", min_date) if min_date
    relation = relation.where("#{field} <= ?", max_date) if max_date
    relation
  end
end
