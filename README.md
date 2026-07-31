# FirstOfficer

![FirstOfficer Crew](image.png)

Welcome to **FirstOfficer**, a modernized and upgraded fork of the original `firstmate` project. 

FirstOfficer takes the solid foundation of its predecessor and propels it into the future, bringing a modernized architecture, enhanced features, and a sci-fi inspired vision to the helm. Whether you are navigating complex deployments, orchestrating tasks, or managing your crew of services, FirstOfficer is designed to be your dependable second-in-command.

## Requirements

- A verified primary agent harness: Claude Code, Grok, Pi, `pi-signed`, Codex, or OpenCode.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- The CLI and dependencies for your selected runtime backend; tmux is the reference default.

Backend-specific setup is linked in [Documentation](#documentation).

## Documentation

- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional X mode, the files you set, and harness support.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/tmux-backend.md](docs/tmux-backend.md) - current setup and limits for the tmux reference backend.
- [docs/herdr-backend.md](docs/herdr-backend.md) - current setup, safety boundaries, and limits for the experimental Herdr backend.
- [docs/zellij-backend.md](docs/zellij-backend.md) - current setup and limits for the experimental Zellij backend.
- [docs/orca-backend.md](docs/orca-backend.md) - current setup and limits for the experimental Orca backend.
- [docs/cmux-backend.md](docs/cmux-backend.md) - current setup, socket security, and limits for the experimental cmux backend.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.

## 🙏 Acknowledgements and Credits

This project would not exist without the fantastic work that preceded it. 

**Full credit and our deepest gratitude go to the original author, Kun Chen, for his open-sourced work on `firstmate`.** FirstOfficer is built directly upon the incredible foundation he created, and we are proud to continue evolving this tool for the open-source community. 

Please check out the original [firstmate repository](#) (if applicable) to see where this journey began.
