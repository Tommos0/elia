defmodule Elia.Shell.LockTest do
  # ISOL-26: one jail at a time mounts a worktree's dependency layer, and the
  # lock is held only for the mount — so it is a queue, not a mutex around the
  # command, and a holder that dies doesn't wedge the worktree.
  use ExUnit.Case, async: false

  alias Elia.Shell.Lock

  # The application starts the lock (ISOL-26); a key per test keeps them apart.
  defp key, do: {:test, make_ref()}

  test "one holder at a time, and the next waiter gets it when it is released" do
    key = key()
    assert :ok = Lock.acquire(key)

    waiter = Task.async(fn -> Lock.acquire(key) end)
    refute Task.yield(waiter, 100), "a second caller must wait for the holder"

    assert :ok = Lock.release(key)
    assert :ok = Task.await(waiter, 1_000)
    assert :ok = Lock.release(key)
  end

  test "waiters are granted in the order they asked" do
    key = key()
    parent = self()
    assert :ok = Lock.acquire(key)

    first =
      Task.async(fn ->
        :ok = Lock.acquire(key)
        send(parent, {:got, 1})
      end)

    Process.sleep(20)

    second =
      Task.async(fn ->
        :ok = Lock.acquire(key)
        send(parent, {:got, 2})
      end)

    Process.sleep(20)

    assert :ok = Lock.release(key)
    assert_receive {:got, 1}, 1_000
    refute_received {:got, 2}

    assert :ok = Lock.release(key)
    assert_receive {:got, 2}, 1_000
    assert :ok = Lock.release(key)

    Task.await_many([first, second], 1_000)
  end

  test "a holder that dies without releasing releases the lock" do
    key = key()
    parent = self()

    pid =
      spawn(fn ->
        :ok = Lock.acquire(key)
        send(parent, :held)
      end)

    assert_receive :held, 1_000

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    assert :ok = Lock.acquire(key, 1_000)
    assert :ok = Lock.release(key)
  end

  test "a caller that can't get the lock in time is told so, and runs anyway" do
    key = key()
    assert :ok = Lock.acquire(key)

    assert :timeout = Lock.acquire(key, 50)

    assert :ok = Lock.release(key)
  end

  test "a caller that gives up waiting leaves no lock behind" do
    key = key()
    assert :ok = Lock.acquire(key)

    waiter = Task.async(fn -> Lock.acquire(key, 50) end)
    assert :timeout = Task.await(waiter, 1_000)
    # The cancel is a cast, so give the lock a moment to process it.
    Process.sleep(20)

    # The waiter gave up and its process is gone; the holder's release must free
    # the lock rather than hand it to a waiter that would never release it.
    assert :ok = Lock.release(key)
    assert :ok = Lock.acquire(key, 200)
    assert :ok = Lock.release(key)
  end

  test "releasing a lock this process doesn't hold changes nothing" do
    key = key()
    assert :ok = Lock.acquire(key)

    holder = Task.async(fn -> Lock.acquire(key) end)
    refute Task.yield(holder, 100)

    # The test process holds it, so this is its own release; a stranger's is a
    # no-op that must not hand the lock to the waiter.
    assert :ok = Lock.release(key)
    assert :ok = Task.await(holder, 1_000)
    assert :ok = Lock.release(key)
  end
end
