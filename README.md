# noctalia-lunatask — source repo for the Lunatask Noctalia plugin

Source repo layout (per Noctalia docs: one dir per plugin + root `catalog.toml`):

```text
noctalia-lunatask/
├── catalog.toml
└── lunatask/            # plugin id snowballons/lunatask
    ├── plugin.toml
    ├── service.luau     # M0: token resolve + ping
    ├── lib/api.luau
    ├── translations/en.json
    └── README.md
```

Roadmap: see `../lunatask-noctalia-plugin-spec.md` (M0–M8).
