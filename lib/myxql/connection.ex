defmodule MyXQL.Connection do
  @moduledoc false

  use DBConnection
  import MyXQL.Protocol.{Flags, Records}
  alias MyXQL.{Client, Cursor, Query, Protocol, Result, TextQuery}

  @disconnect_on_error_codes [
    :ER_MAX_PREPARED_STMT_COUNT_REACHED
  ]

  defstruct [
    :client,
    cursors: %{},
    disconnect_on_error_codes: [],
    ping_timeout: 15_000,
    prepare: :named,
    queries: nil,
    transaction_status: :idle,
    last_ref: nil
  ]

  @impl true
  def connect(opts) do
    prepare = Keyword.get(opts, :prepare, :named)
    ping_timeout = Keyword.get(opts, :ping_timeout, 15_000)
    config = Client.Config.new(opts)

    disconnect_on_error_codes =
      @disconnect_on_error_codes ++ Keyword.get(opts, :disconnect_on_error_codes, [])

    case Client.connect(config) do
      {:ok, %Client{} = client} ->
        state = %__MODULE__{
          client: client,
          prepare: prepare,
          disconnect_on_error_codes: disconnect_on_error_codes,
          ping_timeout: ping_timeout,
          queries: queries_new()
        }

        {:ok, state}

      {:ok, err_packet() = err_packet} ->
        {:error, error(err_packet)}

      {:error, :enoent} ->
        exception = error(:enoent)
        {:local, socket} = config.address
        exception = %{exception | message: exception.message <> " #{inspect(socket)}"}
        {:error, exception}

      {:error, reason} ->
        {:error, error(reason)}
    end
  end

  @impl true
  def disconnect(_reason, state) do
    Client.disconnect(state.client)
  end

  @impl true
  def checkout(state) do
    {:ok, state}
  end

  @impl true
  def checkin(state) do
    {:ok, state}
  end

  @impl true
  def handle_prepare(query, opts, state) do
    query = rename_query(state, query)

    case cached_prepare(query, state) do
      {:ok, _, _} = ok ->
        ok

      {:error, %MyXQL.Error{mysql: %{name: :ER_UNSUPPORTED_PS}}, state} = error ->
        if Keyword.get(opts, :query_type) == :binary_then_text do
          query = %MyXQL.TextQuery{statement: query.statement}
          {:ok, query, state}
        else
          error
        end

      other ->
        other
    end
  end

  @impl true
  def handle_execute(%Query{} = query, params, _opts, state) do
    cached_execute(query, params, state)
  end

  def handle_execute(%TextQuery{statement: statement} = query, [], _opts, state) do
    Client.com_query(state.client, statement)
    |> result(query, state)
  end

  @impl true
  def handle_close(%Query{} = query, _opts, state) do
    {:ok, nil, close(query, state)}
  end

  @impl true
  def ping(state) do
    case Client.com_ping(state.client, state.ping_timeout) do
      {:ok, ok_packet(status_flags: status_flags)} ->
        {:ok, put_status(state, status_flags)}

      {:ok, err_packet() = err_packet} ->
        {:disconnect, error(err_packet), state}

      {:error, reason} ->
        {:disconnect, error(reason), state}
    end
  end

  @impl true
  def handle_begin(opts, %{transaction_status: status} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when status == :idle ->
        handle_transaction(:begin, "BEGIN", s)

      :savepoint when status == :transaction ->
        handle_transaction(:begin, "SAVEPOINT myxql_savepoint", s)

      mode when mode in [:transaction, :savepoint] ->
        {status, s}
    end
  end

  @impl true
  def handle_commit(opts, %{transaction_status: status} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when status == :transaction ->
        handle_transaction(:commit, "COMMIT", s)

      :savepoint when status == :transaction ->
        handle_transaction(:commit, "RELEASE SAVEPOINT myxql_savepoint", s)

      mode when mode in [:transaction, :savepoint] ->
        {status, s}
    end
  end

  @impl true
  def handle_rollback(opts, %{transaction_status: status} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when status == :transaction ->
        handle_transaction(:rollback, "ROLLBACK", s)

      :savepoint when status == :transaction ->
        with {:ok, _result, s} <-
               handle_transaction(:rollback, "ROLLBACK TO SAVEPOINT myxql_savepoint", s) do
          handle_transaction(:rollback, "RELEASE SAVEPOINT myxql_savepoint", s)
        end

      mode when mode in [:transaction, :savepoint] ->
        {status, s}
    end
  end

  @impl true
  def handle_status(_opts, s) do
    {s.transaction_status, s}
  end

  @impl true
  def handle_declare(query, params, _opts, state) do
    with {:ok, query, state} <- maybe_reprepare(query, state) do
      cursor = %Cursor{ref: make_ref()}

      state = %{
        state
        | cursors: Map.put(state.cursors, cursor.ref, {:params, params, query.statement_id})
      }

      {:ok, query, cursor, state}
    end
  end

  @impl true
  def handle_fetch(query, %Cursor{ref: cursor_ref}, opts, state) do
    case Map.fetch!(state.cursors, cursor_ref) do
      {:params, params, statement_id} ->
        fetch_first(%{query | statement_id: statement_id}, cursor_ref, params, opts, state)

      {:column_defs, column_defs, statement_id} ->
        fetch_next(%{query | statement_id: statement_id}, cursor_ref, column_defs, opts, state)
    end
  end

  defp fetch_first(query, cursor_ref, params, _opts, state) do
    case Client.com_stmt_execute(state.client, query.statement_id, params, :cursor_type_read_only) do
      {:ok, resultset(column_defs: column_defs, status_flags: status_flags)} = result ->
        {:ok, _query, result, state} = result(result, query, state)

        cursors =
          Map.put(state.cursors, cursor_ref, {:column_defs, column_defs, query.statement_id})

        state = put_status(%{state | cursors: cursors}, status_flags)

        if has_status_flag?(status_flags, :server_status_cursor_exists) do
          {:cont, result, state}
        else
          {:halt, result, state}
        end

      other ->
        result(other, query, state)
    end
  end

  defp fetch_next(query, _cursor_ref, column_defs, opts, state) do
    max_rows = Keyword.get(opts, :max_rows, 500)
    result = Client.com_stmt_fetch(state.client, query.statement_id, column_defs, max_rows)

    case result do
      {:ok, resultset(status_flags: status_flags)} ->
        with {:ok, _query, result, state} <- result(result, query, state) do
          if has_status_flag?(status_flags, :server_status_cursor_exists) do
            {:cont, result, state}
          else
            true = has_status_flag?(status_flags, :server_status_last_row_sent)
            {:halt, result, state}
          end
        end

      other ->
        result(other, query, state)
    end
  end

  @impl true
  def handle_deallocate(%{name: ""} = query, _cursor, _opts, state) do
    {:ok, nil, close(query, state)}
  end

  def handle_deallocate(query, _cursor, _opts, state) do
    case Client.com_stmt_reset(state.client, query.statement_id) do
      {:ok, ok_packet(status_flags: status_flags)} ->
        {:ok, nil, put_status(state, status_flags)}

      other ->
        result(other, query, state)
    end
  end

  ## Internals

  defp result(
         {:ok,
          ok_packet(
            last_insert_id: last_insert_id,
            affected_rows: affected_rows,
            status_flags: status_flags,
            num_warnings: num_warnings
          )},
         query,
         state
       ) do
    result = %Result{
      connection_id: state.client.connection_id,
      last_insert_id: last_insert_id,
      num_rows: affected_rows,
      num_warnings: num_warnings
    }

    {:ok, query, result, put_status(state, status_flags)}
  end

  defp result(
         {:ok,
          resultset(
            column_defs: column_defs,
            num_rows: num_rows,
            rows: rows,
            status_flags: status_flags,
            num_warnings: num_warnings
          )},
         query,
         state
       ) do
    columns = Enum.map(column_defs, &elem(&1, 1))

    result = %Result{
      connection_id: state.client.connection_id,
      columns: columns,
      num_rows: num_rows,
      rows: rows,
      num_warnings: num_warnings
    }

    {:ok, query, result, put_status(state, status_flags)}
  end

  defp result({:ok, err_packet() = err_packet}, query, state) do
    exception = error(err_packet, query, state)
    maybe_disconnect(exception, state)
  end

  defp result({:error, :multiple_results}, _query, _state) do
    raise RuntimeError, "returning multiple results is not yet supported"
  end

  defp result({:error, reason}, _query, state) do
    {:disconnect, error(reason), state}
  end

  defp error(reason, %{statement: statement}, state) do
    error(reason, statement, state)
  end

  defp error(reason, statement, state) do
    exception = error(reason)
    %MyXQL.Error{exception | statement: statement, connection_id: state.client.connection_id}
  end

  defp error(err_packet(code: code, message: message)) do
    name = Protocol.error_code_to_name(code)
    %MyXQL.Error{message: "(#{code}) (#{name}) " <> message, mysql: %{code: code, name: name}}
  end

  defp error(reason) do
    %DBConnection.ConnectionError{message: format_reason(reason)}
  end

  defp format_reason(:timeout), do: "timeout"
  defp format_reason(:closed), do: "socket closed"

  defp format_reason({:tls_alert, {:bad_record_mac, _}} = reason) do
    versions = :ssl.versions()[:supported]

    """
    #{:ssl.format_error({:error, reason})}

    You might be using TLS version not supported by the server.
    Protocol versions reported by the :ssl application: #{inspect(versions)}.
    Set `:ssl_opts` in `MyXQL.start_link/1` to force specific protocol versions.
    """
  end

  defp format_reason(reason) when is_atom(reason) do
    List.to_string(:inet.format_error(reason))
  end

  defp format_reason(reason) do
    case :ssl.format_error(reason) do
      'Unexpected error' ++ _ ->
        inspect(reason)

      message ->
        List.to_string(message)
    end
  end

  defp maybe_disconnect(exception, state) do
    %MyXQL.Error{mysql: %{name: error_name}} = exception

    if error_name in state.disconnect_on_error_codes do
      {:disconnect, exception, state}
    else
      {:error, exception, state}
    end
  end

  defp handle_transaction(call, statement, state) do
    case Client.com_query(state.client, statement) do
      {:ok, ok_packet()} = ok ->
        {:ok, _query, result, state} = result(ok, call, state)
        {:ok, result, state}

      other ->
        result(other, statement, state)
    end
  end

  defp transaction_status(status_flags) do
    if has_status_flag?(status_flags, :server_status_in_trans) do
      :transaction
    else
      :idle
    end
  end

  defp put_status(state, status_flags) do
    %{state | transaction_status: transaction_status(status_flags)}
  end

  defp rename_query(%{prepare: :force_named}, query),
    do: %{query | name: "force_#{System.unique_integer([:positive])}"}

  defp rename_query(%{prepare: :named}, query),
    do: query

  defp rename_query(%{prepare: :unnamed}, query),
    do: %{query | name: ""}

  defp maybe_reprepare(%{ref: ref} = query, %{last_ref: ref} = state), do: {:ok, query, state}

  defp maybe_reprepare(query, state) do
    if cached_query = queries_get(state, query) do
      {:ok, cached_query, state}
    else
      prepare(query, state)
    end
  end

  # Close unnamed queries after executing them
  defp maybe_close(%Query{name: ""} = query, state), do: close(query, state)
  defp maybe_close(_query, state), do: state

  defp close(%{ref: ref} = query, %{last_ref: ref} = state) do
    close(query, %{state | last_ref: nil})
  end

  defp close(query, state) do
    :ok = Client.com_stmt_close(state.client, query.statement_id)
    queries_delete(state, query)
    state
  end

  ## Cache query handling

  defp cache_key(%MyXQL.Query{cache: :reference, name: name}), do: name
  defp cache_key(%MyXQL.Query{cache: :statement, statement: statement}), do: statement

  defp queries_new(), do: :ets.new(__MODULE__, [:set, :public])

  defp queries_put(%{queries: nil}, _), do: :ok
  defp queries_put(_state, %Query{name: ""}), do: :ok

  defp queries_put(
         state,
         %Query{cache: :reference, num_params: num_params, statement_id: statement_id, ref: ref} =
           query
       ) do
    try do
      :ets.insert(state.queries, {cache_key(query), {num_params, statement_id, ref}})
    rescue
      ArgumentError ->
        :ok
    else
      true -> :ok
    end
  end

  defp queries_put(state, %Query{cache: :statement} = query) do
    try do
      :ets.insert(state.queries, {cache_key(query), query})
    rescue
      ArgumentError ->
        :ok
    else
      true -> :ok
    end
  end

  defp queries_delete(%{queries: nil}, _), do: :ok
  defp queries_delete(_state, %Query{name: ""}), do: :ok

  defp queries_delete(state, %Query{} = query) do
    try do
      :ets.delete(state.queries, cache_key(query))
    rescue
      ArgumentError -> :ok
    else
      true -> :ok
    end
  end

  defp queries_get(%{queries: nil}, _), do: nil
  defp queries_get(_state, %Query{name: ""}), do: nil

  defp queries_get(state, %Query{cache: :reference} = query) do
    try do
      :ets.lookup_element(state.queries, cache_key(query), 2)
    rescue
      ArgumentError -> nil
    else
      {num_params, statement_id, ref} ->
        %{query | num_params: num_params, statement_id: statement_id, ref: ref}
    end
  end

  defp queries_get(state, %Query{cache: :statement} = query) do
    try do
      :ets.lookup_element(state.queries, cache_key(query), 2)
    rescue
      ArgumentError -> nil
    end
  end

  ## Caching

  defp cached_prepare(query, state) do
    if cached_query = queries_get(state, query) do
      {:ok, cached_query, %{state | last_ref: cached_query.ref}}
    else
      with {:ok, query, state} <- prepare(query, state) do
        queries_put(state, query)
        {:ok, query, %{state | last_ref: query.ref}}
      end
    end
  end

  defp cached_execute(query, params, state) do
    with {:ok, query, state} <- maybe_reprepare(query, state) do
      execute(query, params, state)
    end
  end

  ## Internals

  defp prepare(%Query{statement: statement} = query, state) do
    case Client.com_stmt_prepare(state.client, statement) do
      {:ok, com_stmt_prepare_ok(statement_id: statement_id, num_params: num_params)} ->
        ref = make_ref()
        query = %{query | num_params: num_params, statement_id: statement_id, ref: ref}
        {:ok, query, state}

      result ->
        result(result, query, state)
    end
  end

  defp execute(query, params, state) do
    result =
      Client.com_stmt_execute(
        state.client,
        query.statement_id,
        params,
        :cursor_type_no_cursor
      )

    state = maybe_close(query, state)
    result(result, query, state)
  end
end
