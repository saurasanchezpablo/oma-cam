# Contributing

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Logic goes in `Model.js` (pure, with
tests), system access in `bin/droidcam-helper.sh`, QML stays thin.

## Checks

```bash
node --test tests/                    # Model.js unit tests
bash -n bin/droidcam-helper.sh        # helper syntax
omarchy plugin validate .             # manifest
```

## Trying it

```bash
bash dev/install.sh                   # copy to ~/.config/omarchy/plugins/… and restart the shell
omarchy plugin enable io.github.saurasanchezpablo.droidcam
```

Without a phone, run the mock and point the plugin at it with the stand-in client.
The stand-in never opens a video device, so it can't disturb a camera in use:

```bash
python3 dev/mock_droidcam.py --port 4848 --scenario free
ID=io.github.saurasanchezpablo.droidcam
omarchy-shell $ID configure "{\"mode\":\"wifi\",\"host\":\"127.0.0.1\",\"port\":4848,\"cliPath\":\"$PWD/dev/fake_droidcam_cli.py\"}"
omarchy-shell $ID status
curl -X POST http://127.0.0.1:4848/mock/scenario/drop    # free, pro, busy, drop, stopped, hang, flood, lowbat
```

Never point the real `droidcam-cli` at the mock: it would write the mock's frames
into a real camera device. Set `cliPath` back to `""` when you are done.

The helper can be run by hand too:

```bash
bash bin/droidcam-helper.sh check auto 192.168.1.50 4747 "" droidcam-cli 0
bash bin/droidcam-helper.sh doctor auto "" 4747 "" droidcam-cli
bash bin/droidcam-helper.sh consumers /dev/video0 ""
```

## Conventions

- Commit subjects: imperative, sentence case, no prefix, no trailing period.
- Every user-visible change gets a line in `CHANGELOG.md`.
- No personal data in the repository: example addresses are `192.168.1.50`,
  screenshots come from the mock.
