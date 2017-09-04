module WithPagination
  def with_pagination(request, response)
    tap { @paginator = Gitlab::Serializer::Pagination.new(request, response) }
  end

  def paginated?
    @paginator.present?
  end

  # super is `BaseSerializer#represent` here.
  #
  # we shouldn't try to paginate single resources
  def represent(resource, opts = {})
    if paginated? && resource.respond_to?(:page)
      super(@paginator.paginate(resource), opts)
    else
      super(resource, opts)
    end
  end
end
