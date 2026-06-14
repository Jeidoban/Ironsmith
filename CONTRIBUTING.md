# Contributing

Thanks for contributing to Ironsmith! I really appreciate you taking the time to contribute to this project. Please keep your changes focused and always remember to write tests!

## AI Generated Code

Agent written code has become standard in modern software development, so it's expected that your contributions will be AI generated. Even Ironsmith itself was almost entierly written with Codex. That being said I personally reviewed every line of code it wrote and was the ultimate decision maker with what it produced. I just ask that you do the same with any code you contribute to the project. Thanks for understanding!

## Setup

You need macOS 26 or newer and the Xcode Command Line Tools. Xcode is optional.

Install the command line tools if needed:

```sh
xcode-select --install
```

Build the app:

```sh
script/build.sh
```

Run the app:

```sh
script/build.sh run
```

Run tests:

```sh
script/test.sh
```

## Pull Requests

- Create a branch for your change.
- Keep the PR scoped to one fix or feature.
- Add or update tests for behavior changes.
- Update docs when user-facing behavior or developer workflow changes.
- Do not commit local secrets, `Config/.env`, build outputs, or unrelated editor settings.
- Mention any tests you could not run.

## Issues

For bug reports, include:

- macOS version.
- Ironsmith version or commit.
- Model/provider used, if the issue involves generation.
- Steps to reproduce.
- Expected and actual behavior.

Thank you!