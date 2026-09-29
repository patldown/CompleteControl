//
//  AddSetListView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData

struct AddSetListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var notes = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Set List Details")
                }
            }
            .navigationTitle("New Set List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createSetList()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
    
    private func createSetList() {
        let _ = SetList.create(name: name, notes: notes.isEmpty ? nil : notes, in: viewContext)
        try? viewContext.save()
        dismiss()
    }
}

#Preview {
    AddSetListView()
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
}
