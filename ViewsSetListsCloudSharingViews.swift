//
//  ViewsSetListsCloudSharingViews.swift
//  Midi Set List
//

import CloudKit
import CoreData
import SwiftUI
import UIKit

// MARK: - UICloudSharingController wrapper

struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}
}

// MARK: - Toolbar button

struct CloudShareButton: View {
    let setList: SetList

    @State private var share: CKShare?
    @State private var showingSheet = false
    @State private var isLoading = false

    private var ckContainer: CKContainer {
        CKContainer(identifier: PersistenceController.cloudKitContainerID)
    }

    var body: some View {
        Button {
            createShareIfNeeded()
        } label: {
            if isLoading {
                ProgressView()
                    .frame(width: 20, height: 20)
            } else {
                Label("Share via iCloud", systemImage: "person.crop.circle.badge.plus")
            }
        }
        .disabled(isLoading)
        .sheet(isPresented: $showingSheet) {
            if let share {
                CloudSharingSheet(share: share, container: ckContainer)
                    .ignoresSafeArea()
            }
        }
    }

    private func createShareIfNeeded() {
        isLoading = true
        let pc = PersistenceController.shared.container

        // Reuse existing share if this set list is already shared
        if let existing = (try? pc.fetchShares(matching: [setList.objectID]))?[setList.objectID] {
            share = existing
            isLoading = false
            showingSheet = true
            return
        }

        pc.share([setList], to: nil) { _, newShare, _, error in
            DispatchQueue.main.async {
                isLoading = false
                if let newShare {
                    newShare[CKShare.SystemFieldKey.title] = setList.name as CKRecordValue
                    share = newShare
                    showingSheet = true
                }
            }
        }
    }
}

// MARK: - Song share button

struct CloudSongShareButton: View {
    let song: Song

    @State private var share: CKShare?
    @State private var showingSheet = false
    @State private var isLoading = false

    private var ckContainer: CKContainer {
        CKContainer(identifier: PersistenceController.cloudKitContainerID)
    }

    var body: some View {
        Button {
            createShareIfNeeded()
        } label: {
            if isLoading {
                ProgressView()
                    .frame(width: 20, height: 20)
            } else {
                Label("Share Song via iCloud", systemImage: "person.crop.circle.badge.plus")
            }
        }
        .disabled(isLoading)
        .sheet(isPresented: $showingSheet) {
            if let share {
                CloudSharingSheet(share: share, container: ckContainer)
                    .ignoresSafeArea()
            }
        }
    }

    private func createShareIfNeeded() {
        isLoading = true
        let pc = PersistenceController.shared.container

        if let existing = (try? pc.fetchShares(matching: [song.objectID]))?[song.objectID] {
            share = existing
            isLoading = false
            showingSheet = true
            return
        }

        pc.share([song], to: nil) { _, newShare, _, error in
            DispatchQueue.main.async {
                isLoading = false
                if let newShare {
                    newShare[CKShare.SystemFieldKey.title] = song.name as CKRecordValue
                    share = newShare
                    showingSheet = true
                }
            }
        }
    }
}
