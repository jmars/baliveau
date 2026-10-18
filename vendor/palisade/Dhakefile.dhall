-- Dhakefile.dhall — build palisade's stage3 sandbox core (and probes) with dhake.
--
-- Mirrors the recipe in Makefile (which is kept for the ratan/other consumers
-- that still drive it via `make -C vendor/palisade`).  Building stage3 here is
-- equivalent to `make stage3`; the Dhakefile is the Dhake-native spelling.
--
--     ../../dhake/dhake.com            # build the default target (bin/stage3)
--     ../../dhake/dhake.com stage3     # same
--     ../../dhake/dhake.com probes     # build the syscall probe binaries
--     ../../dhake/dhake.com --list     # list targets
--
-- Requirements: `cosmocc` and `assimilate` on $PATH.

let Action =
      < Shell : Text
      | Copy : { from : Text, to : Text }
      | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } >
      | Rm : < Plain : Text | Recursive : { path : Text, recursive : Bool } >
      | Touch : Text
      | Move : { from : Text, to : Text }
      | Symlink : { from : Text, to : Text }
      | Chmod : { path : Text, mode : Text }
      | Echo : Text
      | Env : { key : Text, value : Text }
      | Run : { argv : List Text }
      >

let Target = { deps : List Text, phony : Bool, recipe : List Action }

-- The vendored cosmocc pledge is linked into stage3 so its patched
-- sys_pledge_linux/kPledge override the precompiled libc's.  It needs GNU
-- extensions and a relaxed warning set (cosmocc's own code trips -Werror), so
-- it is compiled separately from stage3.c (which stays strict c11 + -Werror).
let pledge_relaxed =
      "-Wall -Wextra -Wno-unused-parameter -Wno-sign-compare "
      ++ "-Wno-unused-function -fno-stack-protector"

in  { targets =
        [ { mapKey = "bin/stage3"
          , mapValue =
              { deps =
                  [ "src/palisade/stage3.c"
                  , "src/palisade/cosmo/pledge-rattan.c"
                  ]
              , phony = False
              , recipe =
                  [ < Mkdir = { path = "bin", parents = True } >
                    -- The vendored pledge, compiled separately (relaxed flags).
                  , < Shell =
                        "cosmocc -std=gnu11 " ++ pledge_relaxed ++ " -c "
                      ++ "src/palisade/cosmo/pledge-rattan.c -o bin/pledge-rattan.o"
                    >
                    -- stage3.c itself, strict.
                  , < Shell =
                        "cosmocc -std=c11 -Os -Wall -Wextra -Werror "
                      ++ "-fno-stack-protector -c src/palisade/stage3.c "
                      ++ "-o bin/stage3.o"
                    >
                  , < Shell =
                        "cosmocc -o bin/stage3.ape bin/pledge-rattan.o bin/stage3.o"
                    >
                  , < Shell = "assimilate -f bin/stage3.ape" >
                  , < Move = { from = "bin/stage3.ape", to = "bin/stage3" } >
                  , < Rm = "bin/pledge-rattan.o" >
                  , < Rm = "bin/stage3.o" >
                  ]
              }
          }
        , { mapKey = "stage3"
          , mapValue = { deps = [ "bin/stage3" ], phony = True, recipe = [] : List Action }
          }

        -- ─── probe binaries (used by palisade's own stage3 tests) ──────────
        -- Syscall probes use only glibc-compatible APIs and are built with the
        -- host gcc as static binaries; reverse_order_probe calls cosmocc's
        -- pledge()/unveil(), so it is built with cosmocc + assimilate.
        , { mapKey = "tests/probes/keytest"
          , mapValue = { deps = [ "tests/probes/keytest.c" ], phony = False
                       , recipe = [ < Shell = "gcc -Os -static -o tests/probes/keytest tests/probes/keytest.c" > ] }
          }
        , { mapKey = "tests/probes/ptracetest"
          , mapValue = { deps = [ "tests/probes/ptracetest.c" ], phony = False
                       , recipe = [ < Shell = "gcc -Os -static -o tests/probes/ptracetest tests/probes/ptracetest.c" > ] }
          }
        , { mapKey = "tests/probes/mounttest"
          , mapValue = { deps = [ "tests/probes/mounttest.c" ], phony = False
                       , recipe = [ < Shell = "gcc -Os -static -o tests/probes/mounttest tests/probes/mounttest.c" > ] }
          }
        , { mapKey = "tests/probes/unsharetest"
          , mapValue = { deps = [ "tests/probes/unsharetest.c" ], phony = False
                       , recipe = [ < Shell = "gcc -Os -static -o tests/probes/unsharetest tests/probes/unsharetest.c" > ] }
          }
        , { mapKey = "tests/probes/reverse_order_probe"
          , mapValue =
              { deps = [ "tests/probes/reverse_order_probe.c" ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "cosmocc -Os -o tests/probes/reverse_order_probe.ape "
                      ++ "tests/probes/reverse_order_probe.c"
                    >
                  , < Shell = "assimilate -f tests/probes/reverse_order_probe.ape" >
                  , < Move =
                        { from = "tests/probes/reverse_order_probe.ape"
                        , to = "tests/probes/reverse_order_probe"
                        }
                    >
                  ]
              }
          }
        , { mapKey = "probes"
          , mapValue =
              { deps =
                  [ "tests/probes/keytest"
                  , "tests/probes/ptracetest"
                  , "tests/probes/mounttest"
                  , "tests/probes/unsharetest"
                  , "tests/probes/reverse_order_probe"
                  ]
              , phony = True
              , recipe = [] : List Action
              }
          }
        ]
      , default = "bin/stage3"
      }
