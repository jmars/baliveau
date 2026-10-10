let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "b2-agent-9f3c"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "b2proof-b2-agent-9f3c", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
        , { name = "b2verifier", argv = [ "/usr/fx-agent/bin/fx-agent", "-p", "verify the running system", "--agent", "fx", "--max-turns", "2", "--output", "text" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = Some [ { key = "FX_CHARDEV", value = "/usr/fx-agent/b2-verify.sse" },
                         { key = "VIBE_RUNTIME_CONFIG_DIR", value = "/usr/fx-agent/cfg-b2" },
                         { key = "VIBE_RUNTIME_DIR", value = "/fx/disk/agent-data" },
                         { key = "HOME", value = "/tmp" }
                       ] : Optional (List { key : Text, value : Text }),
            console = Some "console" }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 15000
    , agentService = Some "b2verifier"
    }
