defmodule Sidereon.GNSS.ArchiveIngressTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.ArchiveIngress

  test "stream accumulator retains no more than limit plus one byte" do
    state = ArchiveIngress.new(5)

    assert {:cont, state} = ArchiveIngress.append(state, "ab")
    assert {:cont, state} = ArchiveIngress.append(state, "cde")
    assert {:halt, state} = ArchiveIngress.append(state, "fghijkl")
    assert state.size == 6
    assert state.overflow?
    assert {:ok, "abcdef", true} = ArchiveIngress.finish(state)
    assert {:halt, ^state} = ArchiveIngress.append(state, "more")
  end

  test "Req callback accumulates chunks and records overflow in response private data" do
    into = ArchiveIngress.req_into(5)
    request = Req.new()
    response = Req.Response.new(status: 200)

    assert {:cont, {request, response}} = into.({:data, "ab"}, {request, response})
    assert {:cont, {request, response}} = into.({:data, "cde"}, {request, response})
    assert {:halt, {_request, response}} = into.({:data, "fgh"}, {request, response})
    assert {:ok, "abcdef", true} = ArchiveIngress.finish_response(response, 5)
  end

  test "bounded file read accepts exact limit and rejects one byte beyond it" do
    root = Path.join(System.tmp_dir!(), "sidereon-archive-ingress-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    exact = Path.join(root, "exact")
    oversized = Path.join(root, "oversized")
    File.write!(exact, "abcde")
    File.write!(oversized, "abcdef" <> String.duplicate("x", 1_000_000))

    assert {:ok, "abcde"} = ArchiveIngress.read_file(exact, 5)
    assert {:error, {:download_size_exceeded, 5}} = ArchiveIngress.read_file(oversized, 5)
  end

  test "bounded reader continues after short reads until overflow is proven" do
    {:ok, chunks} = Agent.start_link(fn -> ["ab", "c", "de", "f", "unread"] end)
    {:ok, requests} = Agent.start_link(fn -> [] end)

    reader = fn requested ->
      Agent.update(requests, &[requested | &1])

      Agent.get_and_update(chunks, fn
        [chunk | rest] -> {{:ok, chunk}, rest}
        [] -> {:eof, []}
      end)
    end

    assert {:error, {:download_size_exceeded, 5}} = ArchiveIngress.read_bounded(reader, 5)
    assert Agent.get(requests, &Enum.reverse/1) == [6, 4, 3, 1]
    assert Agent.get(chunks, & &1) == ["unread"]
  end

  test "bounded reader accepts exact-size content after any number of short reads" do
    {:ok, chunks} = Agent.start_link(fn -> ["a", "bc", "de"] end)

    reader = fn _requested ->
      Agent.get_and_update(chunks, fn
        [chunk | rest] -> {{:ok, chunk}, rest}
        [] -> {:eof, []}
      end)
    end

    assert {:ok, "abcde"} = ArchiveIngress.read_bounded(reader, 5)
  end
end
