# Spec Delta

## REMOVED Requirements

### Requirement: New work does not grow AppState
**Reason**: `AppState` is split into the shared homes and removed in v4.
**Migration**: The requirement "New work uses the shared homes" replaces it; `swift/TigerDuck/AGENTS.md` lists the homes.

## ADDED Requirements

### Requirement: New work uses the shared homes
The app AGENTS.md SHALL list the home of every shared rule and the size budget, and direct agents to
put new state in the feature's view model or the store that owns the data, never in a new
coordinator that spans features.

#### Scenario: Agent adds feature state
- **WHEN** an agent plans to add state that one feature needs
- **THEN** the app AGENTS.md directs it to that feature's view model, or to the store when other features read the same data

#### Scenario: Agent needs a shared rule
- **WHEN** an agent needs a rule another feature already uses, such as whether data may be sent
- **THEN** the app AGENTS.md line for that rule names the type and path to call
