# Contributing

## Issues and pull requests

Creating issues and pull requests is restricted to collaborators with `write`
access. Other users can use Discussions, if enabled, or contact the maintainer.
Deletion and force-pushes are disabled on the default branch.

## Code and documentation

The application uses AKS, Istio, a BFF and private Blob Storage.
See [architecture](docs/arquitetura.md) and [deployment](docs/deploy.md).
Functional provisioning must work without optional test identities or test
`db_owner` grants. The [ACA deployment](docs/legacy/aca.md) is maintained separately.

Write direct technical descriptions of components, parameters, behavior and
errors. Avoid slogans, rhetorical questions, em/en dashes and repeated generic
warnings. Preserve commands and document specific limitations.

Run the relevant checks in [validation](docs/validacao.md). CI uses local/mocked
services. Live Entra/OBO tests require an authorized environment and manual login.
Do not deploy or delete Azure resources for a documentation-only change.

Use placeholders and synthetic fixtures. Do not commit personal accounts,
environment identifiers, credentials, deployment state or authentication traces.
Follow the [publication checklist](docs/publicacao.md). Regenerate the
[HTML presentation](docs/apresentacao.md) after changing its sources.
