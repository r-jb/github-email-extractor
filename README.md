<p align="center"><img src="https://raw.githubusercontent.com/r-jb/github-email-extractor/media/showcase.webp" alt="GitHub Email Extractor" height="500"></p>

# GitHub Email Extractor

Extract and compile email addresses from GitHub users, organizations, and Git repositories, all from commit metadata.

## Installation

<details open><summary>Using wget</summary>

```bash
  wget https://raw.githubusercontent.com/r-jb/github-email-extractor/main/gh-email.sh
  chmod +x gh-email.sh
  ./gh-email.sh
```

</details>

<details><summary>Using curl</summary>

```bash
  curl -O https://raw.githubusercontent.com/r-jb/github-email-extractor/main/gh-email.sh
  chmod +x gh-email.sh
  ./gh-email.sh
```

</details>

<details><summary>Using an alias</summary>

```bash
  alias gh-email="$(curl -fsSL https://raw.githubusercontent.com/r-jb/github-email-extractor/main/gh-email.sh | sh)"
```

</details>

## Requirements

- bash 4+
- git
- [gh cli](https://cli.github.com/) authenticated

## Notes

- Why use GitHub CLI instead of requesting GitHub's API directly ?

[Currently](https://docs.github.com/en/rest/overview/resources-in-the-rest-api#rate-limits), GitHub's API only allows for 60 unauthenticated requests per hour, which may not be sufficient for most use cases.
