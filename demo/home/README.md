Pins the `global` tab of the destination-picker recording.

`bliz record --pick` resolves the global scope against `$HOME`, so without this
the demo would show whatever agent directories happen to exist on the machine
that recorded it. `build.zig` points HOME here for that one run. The single
`.claude/skills` directory is enough to make the global tab show both groups:
the agents that are installed on this (fake) account, and the ones that would
have to be created.
