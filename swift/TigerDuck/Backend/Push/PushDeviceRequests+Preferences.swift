import Defaults
import Foundation
import os

nonisolated extension PushDeviceRequests {
    func sendServerPushOptOut(
        _ optOut: Bool, deviceToken: String?, for signIn: SignIn
    ) async throws {
        let uuid = identity.uuid
        do {
            var sent = false, refusal: PushAPIError?
            do {
                sent = try await sendAnonymous(deviceToken: deviceToken, serverPushEnabled: !optOut)
            } catch let error as PushAPIError where error.refusesDeviceSecret {
                refusal = error
            }
            if await apiClient.hasAuthSession() {
                _ = try await apiClient.updateDevicePreferences(
                    deviceId: uuid, serverPushEnabled: !optOut, for: signIn
                )
                sent = true
            } else if let refusal, !PushIdentity.storesNoSession(in: keychain) {
                throw refusal
            }
            await MainActor.run { Defaults[.serverPushUserOptOut] = optOut }
            if sent {
                logger.info("server push opt-out=\(optOut, privacy: .public) propagated")
            } else {
                logger.info("server push opt-out=\(optOut, privacy: .public) kept for the next announce")
            }
        } catch {
            logger.error("server push opt-out did not propagate: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func sendBulletinPushEnabled(_ enabled: Bool, for signIn: SignIn) async throws {
        do {
            let response = try await apiClient.updateDevicePreferences(
                deviceId: identity.uuid, bulletinPushEnabled: enabled, for: signIn
            )
            guard response.bulletinPushEnabled == enabled else {
                throw PushAPIError.invalidResponse
            }
            await MainActor.run { Defaults[.bulletinPushEnabled] = enabled }
            logger.info("bulletin push enabled=\(enabled, privacy: .public) propagated")
        } catch {
            logger.error("bulletin push enabled=\(enabled, privacy: .public) did not propagate: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func sendCloudSyncEnabled(_ enabled: Bool, for signIn: SignIn) async {
        do {
            _ = try await apiClient.updateDevicePreferences(
                deviceId: identity.uuid,
                cloudSyncEnabled: enabled,
                for: signIn
            )
            logger.info("[sync] cloud_sync_enabled=\(enabled, privacy: .public) PATCH succeeded")
        } catch {
            logger.error("[sync] cloud_sync_enabled=\(enabled, privacy: .public) PATCH failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func sendSyncPreferences() async {
        let sent = SyncPreferences.current, signIn = signIns.currentSignIn
        Defaults[.syncPreferencesPushPending] = true
        do {
            _ = try await apiClient.updateDevicePreferences(
                deviceId: identity.uuid,
                syncCourses: sent.courses,
                syncCourseColors: sent.courseColors,
                syncCourseNames: sent.courseNames,
                syncAssignments: sent.assignments,
                syncAssignmentReminders: sent.assignmentReminders,
                syncLiveActivity: sent.liveActivity,
                for: signIn
            )
            if SyncPreferences.current == sent {
                Defaults[.syncPreferencesPushPending] = false
            }
        } catch {
            logger.error("[sync] preferences PATCH failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private nonisolated struct SyncPreferences: Equatable, Sendable {
        let courses: Bool
        let courseColors: Bool
        let courseNames: Bool
        let assignments: Bool
        let assignmentReminders: Bool
        let liveActivity: Bool

        static var current: SyncPreferences {
            SyncPreferences(
                courses: Defaults[.syncCourses],
                courseColors: Defaults[.syncCourseColors],
                courseNames: Defaults[.syncCourseNames],
                assignments: Defaults[.syncAssignments],
                assignmentReminders: Defaults[.syncAssignmentReminders],
                liveActivity: Defaults[.syncLiveActivity]
            )
        }
    }
}
