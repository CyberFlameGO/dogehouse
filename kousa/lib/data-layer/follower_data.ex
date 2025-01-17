defmodule Kousa.Data.Follower do
  import Ecto.Query

  @fetch_limit 21

  @spec get_followers_online_and_not_in_a_room(String.t()) :: [Beef.Follow.t()]
  def get_followers_online_and_not_in_a_room(user_id) do
    from(
      f in Beef.Follow,
      inner_join: u in Beef.User,
      on: f.followerId == u.id,
      where: f.userId == ^user_id and u.online == true and is_nil(u.currentRoomId)
    )
    |> Beef.Repo.all()
  end

  def bulk_insert(follows) do
    Beef.Repo.insert_all(
      Beef.Follow,
      follows,
      on_conflict: :nothing
    )
  end

  def is_following_me(user_id, user_id_to_check) do
    not is_nil(
      from(
        f in Beef.Follow,
        where: f.userId == ^user_id and f.followerId == ^user_id_to_check
      )
      |> Beef.Repo.one()
    )
  end

  # fetch the users I follow that are online
  def fetch_following_online(user_id, offset \\ 0) do
    max_room_size = Application.fetch_env!(:kousa, :max_room_size)

    items =
      from(
        f in Beef.Follow,
        inner_join: u in Beef.User,
        on: f.userId == u.id,
        left_join: f2 in Beef.Follow,
        on: f2.userId == ^user_id and f2.followerId == u.id,
        left_join: cr in Beef.Room,
        on: u.currentRoomId == cr.id,
        where:
          f.followerId == ^user_id and
            (is_nil(cr.isPrivate) or
               (cr.isPrivate == false and cr.numPeopleInside < ^max_room_size)),
        select: %{u | currentRoom: cr, followsYou: not is_nil(f2.userId)},
        limit: ^@fetch_limit,
        offset: ^offset,
        order_by: [desc: u.online]
      )
      |> Beef.Repo.all()

    {Enum.slice(items, 0, -1 + @fetch_limit),
     if(length(items) == @fetch_limit, do: -1 + offset + @fetch_limit, else: nil)}
  end

  def fetch_invite_list(user_id, offset \\ 0) do
    user = Kousa.Data.User.get_by_id(user_id)

    items =
      from(
        f in Beef.Follow,
        inner_join: u in Beef.User,
        on: f.followerId == u.id,
        where:
          f.userId == ^user_id and u.online == true and
            (u.currentRoomId != ^user.currentRoomId or is_nil(u.currentRoomId)),
        select: u,
        limit: ^@fetch_limit,
        offset: ^offset
      )
      |> Beef.Repo.all()

    {Enum.slice(items, 0, -1 + @fetch_limit),
     if(length(items) == @fetch_limit, do: -1 + offset + @fetch_limit, else: nil)}
  end

  def get_followers(user_id, user_id_to_get_followers_for, offset \\ 20) do
    items =
      from(
        f in Beef.Follow,
        where: f.userId == ^user_id_to_get_followers_for,
        inner_join: u in Beef.User,
        on: f.followerId == u.id,
        left_join: f2 in Beef.Follow,
        on: f2.userId == u.id and f2.followerId == ^user_id,
        select: %{u | youAreFollowing: not is_nil(f2.userId)},
        limit: ^@fetch_limit,
        offset: ^offset
      )
      |> Beef.Repo.all()

    {Enum.slice(items, 0, -1 + @fetch_limit),
     if(length(items) == @fetch_limit, do: -1 + offset + @fetch_limit, else: nil)}
  end

  def get_following(user_id, user_id_to_get_following_for, offset \\ 20) do
    items =
      from(
        f in Beef.Follow,
        where: f.followerId == ^user_id_to_get_following_for,
        inner_join: u in Beef.User,
        on: f.userId == u.id,
        left_join: f2 in Beef.Follow,
        on: f2.userId == u.id and f2.followerId == ^user_id,
        select: %{u | youAreFollowing: not is_nil(f2.userId)},
        limit: ^@fetch_limit,
        offset: ^offset
      )
      |> Beef.Repo.all()

    {Enum.slice(items, 0, -1 + @fetch_limit),
     if(length(items) == @fetch_limit, do: -1 + offset + @fetch_limit, else: nil)}
  end

  def delete(user_id, follower_id) do
    {rows_affected, _} =
      from(f in Beef.Follow, where: f.userId == ^user_id and f.followerId == ^follower_id)
      |> Beef.Repo.delete_all()

    if rows_affected == 1 do
      from(u in Beef.User,
        where: u.id == ^user_id,
        update: [
          inc: [
            numFollowers: -1
          ]
        ]
      )
      |> Beef.Repo.update_all([])

      from(u in Beef.User,
        where: u.id == ^follower_id,
        update: [
          inc: [
            numFollowing: -1
          ]
        ]
      )
      |> Beef.Repo.update_all([])
    end
  end

  def insert(data) do
    %Beef.Follow{}
    |> Beef.Follow.insert_changeset(data)
    |> Beef.Repo.insert()
    |> case do
      {:ok, _} ->
        # TODO: eliminate N+1 by setting up changesets
        # in an idiomatic fashion.

        from(u in Beef.User,
          where: u.id == ^data.userId,
          update: [
            inc: [
              numFollowers: 1
            ]
          ]
        )
        |> Beef.Repo.update_all([])

        from(u in Beef.User,
          where: u.id == ^data.followerId,
          update: [
            inc: [
              numFollowing: 1
            ]
          ]
        )
        |> Beef.Repo.update_all([])

      error ->
        error
    end
  end

  def get_info(me_id, other_user_id) do
    from(f in Beef.Follow,
      where:
        (f.userId == ^me_id and f.followerId == ^other_user_id) or
          (f.userId == ^other_user_id and f.followerId == ^me_id),
      limit: 2
    )
    |> Beef.Repo.all()
    |> case do
      # when both follow each other there should be two results.
      [_, _] ->
        %{followsYou: true, youAreFollowing: true}

      # when following is unidirectional, there should be one result.
      # this susses out the direction of that relationship
      [%{userId: ^me_id, followerId: ^other_user_id}] ->
        %{followsYou: true, youAreFollowing: false}

      [%{userId: ^other_user_id, followerId: ^me_id}] ->
        %{followsYou: false, youAreFollowing: true}

      # no relationship, no entries.
      [] ->
        %{followsYou: false, youAreFollowing: false}
    end
  end
end
