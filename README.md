# noctalia-lunatask — source repo for the Lunatask Noctalia plugin

Source repo layout (one dir per plugin + root `catalog.toml`):

```text
noctalia-lunatask/
├── catalog.toml
├── LICENSE (MIT)
└── lunatask/            # plugin id snowballons/lunatask
    ├── plugin.toml      # manifest (settings, service/panel/launcher/widget)
    ├── service.luau     # queue, HTTP, registry owner, reconcile, watchdog
    ├── panel.luau       # Tasks / Notes / Journal manager panel
    ├── launcher.luau    # /lt quick capture + registry search
    ├── widget.luau      # bar glyph opening the panel
    ├── lib/api.luau     # transport + response classification
    ├── lib/registry.luau# atomic registry load/save
    ├── lib/ids.luau     # source_id minting, date + day-label helpers
    ├── translations/en.json
    ├── tools/mock_*.lua # headless test harnesses (lua tools/mock_*.lua)
    ├── tools/smoke-m0.sh
    └── README.md        # user documentation (plugin store page)
```

Status: v1.0.0. Test with stock `lua` (`tools/mock_*.lua`), lint with
`noctalia plugins lint lunatask/`, develop via a `path` source.
