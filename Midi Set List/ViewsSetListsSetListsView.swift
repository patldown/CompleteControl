//
//  SetListsView.swift
//  Midi Set List
//
//  Created by Patrick Downey on 9/25/26.
//

import SwiftUI
import CoreData

struct SetListsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(sortDescriptors: [SortDescriptor(\.dateModified, order: .reverse)]) private var setLists: FetchedResults<SetList>
    
    @State private var showingAddSetList = false
    @State private var searchText = ""
    
    var filteredSetLists: [SetList] {
        if searchText.isEmpty {
            return Array(setLists)
        }
        return setLists.filter { setList in
            setList.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSetLists) { setList in
                    NavigationLink {
                        SetListDetailView(setList: setList)
                    } label: {
                        SetListRowView(setList: setList)
                    }
                }
                .onDelete(perform: deleteSetLists)
            }
            .navigationTitle("Set Lists")
            .searchable(text: $searchText, prompt: "Search set lists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSetList = true
                    } label: {
                        Label("Add Set List", systemImage: "plus")
                    }
                }
                
                ToolbarItem(placement: .secondaryAction) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showingAddSetList) {
                AddSetListView()
            }
            .overlay {
                if setLists.isEmpty {
                    ContentUnavailableView {
                        Label("No Set Lists", systemImage: "list.bullet")
                    } description: {
                        Text("Create your first set list to organize songs for performances")
                    } actions: {
                        Button("Create Set List") {
                            showingAddSetList = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
    
    private func deleteSetLists(at offsets: IndexSet) {
        for index in offsets {
            viewContext.delete(filteredSetLists[index])
        }
        try? viewContext.save()
    }
}

struct SetListRowView: View {
    let setList: SetList
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(setList.name)
                .font(.headline)
            
            HStack(spacing: 12) {
                Label("\(setList.songs.count)", systemImage: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if setList.totalCommandCount > 0 {
                    Text("•")
                        .foregroundStyle(.secondary)
                    
                    Label("\(setList.totalCommandCount)", systemImage: "command")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let notes = setList.notes, !notes.isEmpty {
                    Text("•")
                        .foregroundStyle(.secondary)
                    
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Text("Modified \(setList.dateModified.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let ctx = PersistenceController.preview.viewContext
    let s1 = Song.create(name: "Sweet Home Alabama", artist: "Lynyrd Skynyrd", in: ctx)
    let s2 = Song.create(name: "Wonderwall", artist: "Oasis", in: ctx)
    let sl = SetList.create(name: "Friday Night Gig", notes: "Downtown venue", in: ctx)
    sl.addSong(s1); sl.addSong(s2)
    try? ctx.save()
    return NavigationStack { SetListsView() }
        .environment(\.managedObjectContext, ctx)
}
