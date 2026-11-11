# Workflows waiting to be moved

`ci.yml` and `live.yml` belong in `.github/workflows/`. The token that
pushed this branch could not write workflow files, so they wait here. Move
them with an account that can (`git mv ci-pending/*.yml .github/workflows/`)
and delete this directory.
