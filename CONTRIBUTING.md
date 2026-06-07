# Contributing to GW Router Logger

First off, thank you for considering contributing to GW Router Logger! It's people like you that make it a great tool.

## Where do I go from here?

If you've noticed a bug or have a feature request, make sure to check our Issues to see if someone else has already created one. If not, go ahead and make one!

## Fork & create a branch

If this is something you think you can fix, then fork GW Router Logger and create a branch with a descriptive name.

A good branch name would be (where issue #325 is the ticket you're working on):

```sh
# git checkout -b 325-add-new-feature
```

## Get the test suite running

This project consists of PowerShell scripts. Currently, there is no automated test suite. Please test your changes manually in a local Windows environment with PowerShell 5.1+ to ensure they do not break existing functionality. Verify that the installer, uninstaller, CLI script, and tray application all function as expected.

## Implement your fix or feature

At this point, you're ready to make your changes! Feel free to ask for help; everyone is a beginner at first.

## Make a Pull Request

At this point, you should switch back to your main branch and make sure it's up to date with GW Router Logger's main branch. Then update your feature branch from your local copy of main, and push it!

Finally, go to GitHub and make a Pull Request :D

## Keeping your Pull Request updated

If a maintainer asks you to "rebase" your PR, they're saying that a lot of code has changed, and that you need to update your branch so it's easier to merge.

## Code of Conduct

Please note that this project is released with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.
