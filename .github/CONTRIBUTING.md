# Contributing to pgFirstAid

Thank you for your interest in contributing to pgFirstAid! This project is community-driven, and contributions of all kinds are welcome.

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/3/0/code_of_conduct/). By participating, you agree to uphold a welcoming and inclusive environment.

## Ways to Contribute

- **New health checks** - Propose or implement checks for database issues not yet covered
- **Bug fixes** - Found something broken? PRs welcome
- **Documentation** - Improve README, add examples, or clarify explanations
- **Testing** - Validate checks across PostgreSQL versions and cloud providers
- **Feature requests** - Open an issue describing your idea

## Development Setup

The `testing/` directory contains integration and pgTAP coverage used to validate pgFirstAid against live PostgreSQL environments. You can run the test suite against any database you control by setting the standard PostgreSQL connection environment variables described in `testing/integration/README.md`.

## Conventional Commits

This project uses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Every commit message should use this format:

```
<type>[optional scope]: <description>

[optional body]
[optional footer(s)]
```

### Types

| Type | Usage | pgFirstAid example |
|------|-------|--------------------|
| `feat` | A new feature | `feat(checks): add check for inactive replication slots` |
| `fix` | A bug fix | `fix(indexes): avoid false positives for partial duplicate indexes` |
| `chore` | Maintenance, tooling, dependencies | `chore(ci): update PostgreSQL 18 test coverage` |
| `docs` | Documentation changes | `docs: clarify managed view installation steps` |
| `test` | Adding or fixing tests | `test(pgtap): cover long-running query check` |
| `refactor` | Code restructuring with no behavior change | `refactor(views): align duplicate index query across install targets` |
| `style` | Formatting or linting with no logic change | `style: normalize SQL indentation in pgFirstAid.sql` |
| `perf` | Performance improvement | `perf(checks): reduce work in duplicate index detection` |
| `ci` | CI/CD configuration | `ci: run integration suite against PostgreSQL 18` |
| `build` | Build or packaging changes | `build: update integration harness setup` |
| `revert` | Reverting a previous change | `revert: restore previous blocked session recommendation text` |

### Scopes

The optional scope should reference the part of the project you changed:

- `checks` - health check SQL logic
- `views` - `view_pgFirstAid.sql` and `view_pgFirstAid_managed.sql`
- `indexes` - duplicate index and index-related checks
- `sessions` - session and blocking query checks
- `pgtap` - pgTAP coverage in `testing/pgTAP/`
- `integration` - Python integration tests in `testing/integration/`
- `ci` - GitHub Actions and CI configuration
- `docs` - README and contribution docs
- `deps` - dependency updates
- `release` - release preparation

### Examples

```
feat(checks): add lock timeout recommendation for blocked sessions
fix(views): keep managed and self-hosted duplicate index checks aligned
docs: add contribution guidance for test coverage
test(integration): verify long-running query output on seeded data
chore(deps): update pytest in integration harness
```

## Branch Naming

Branches should follow the pattern `type/description`, where `type` is one of the following:

| Branch prefix | When to use |
|---------------|-------------|
| `feat/` | New features |
| `feature/` | New features (alternative to `feat/`) |
| `fix/` | Bug fixes |
| `chore/` | Maintenance tasks and dependency updates |
| `doc/` | Documentation changes |
| `docs/` | Documentation changes (alternative to `doc/`) |
| `test/` | Adding or fixing tests |
| `perf/` | Performance improvements |
| `style/` | Formatting or lint-only changes |
| `ci/` | CI/CD configuration changes |
| `build/` | Build or packaging changes |
| `revert/` | Reverting a previous change |
| `refactor/` | Code restructuring without behavior changes |

Examples:

```
feat/inactive-replication-slot-check
fix/duplicate-index-predicate-matching
docs/update-contributing-guide
test/pgtap-blocked-session-coverage
perf/reduce-duplicate-index-scan-work
style/normalize-sql-indentation
ci/add-postgres-18-matrix-job
build/update-integration-harness-setup
revert/remove-blocked-session-text-change
refactor/align-view-check-ordering
```

## Testing Requirements

Before submitting a PR, test your changes against:

**PostgreSQL Versions:**
- [ ] PostgreSQL 15
- [ ] PostgreSQL 16
- [ ] PostgreSQL 17
- [ ] PostgreSQL 18

**Cloud Providers (if applicable):**
- [ ] AWS RDS
- [ ] AWS Aurora
- [ ] GCP Cloud SQL
- [ ] Azure Database for PostgreSQL

Not everyone has access to all environments. Document what you tested in your PR, and maintainers or other contributors can help validate the rest.

## Submitting a Pull Request

1. Fork the repository
2. Create a branch following the naming convention above (`git checkout -b feat/new-health-check`)
3. Make your changes
4. Keep commits focused and follow Conventional Commits
5. Test against available PostgreSQL versions
6. Submit a PR using the provided template

### PR Review Process

- At least 1 maintainer must approve before merging
- Be patient—this is a side project maintained in spare time
- Expect acknowledgment within a reasonable timeframe, with detailed review to follow
- Squash-merge is preferred. The final commit message should also follow Conventional Commits

## SQL Style Guidelines

Follow the existing code style in the repository:

- Lowercase SQL keywords (`select`, `from`, `where`, `insert`)
- Lowercase for column names, table names, and aliases
- Use meaningful aliases for subqueries and CTEs
- Include comments explaining complex logic
- Match the existing health check structure (severity, category, check_name, etc.)

## Health Check Structure

Each health check should return rows matching this structure:

| Column | Description |
|--------|-------------|
| `severity` | CRITICAL, HIGH, MEDIUM, LOW, or INFO |
| `category` | Grouping (e.g., Table Structure, Index Management) |
| `check_name` | Short descriptive name |
| `object_name` | schema.object being flagged |
| `issue_description` | What the problem is |
| `current_value` | Current state/metrics |
| `recommended_action` | What to do about it |
| `documentation_link` | Link to PostgreSQL docs |

## Questions?

Open an issue or reach out through the channels listed in the README (if applicable.)

---

Thank you for helping make PostgreSQL health monitoring accessible to everyone!
