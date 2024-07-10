//
//  UserList.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 8/29/23.
//

import SwiftUI
import CoreData
import OSLog
#if canImport(TipKit)
import TipKit
#endif

struct UserList: View {

	@StateObject var appState = AppState.shared
	@Environment(\.managedObjectContext) var context
	@EnvironmentObject var bleManager: BLEManager
	@EnvironmentObject var updateCoreDataController: UpdateCoreDataController
	@State private var searchText = ""
	@State private var viaLora = true
	@State private var viaMqtt = true
	@State private var isOnline = false
	@State private var isFavorite = false
	@State private var distanceFilter = false
	@State private var maxDistance: Double = 800000
	@State private var hopsAway: Double = -1.0
	@State private var roleFilter = false
	@State private var deviceRoles: Set<Int> = []
	@State var isEditingFilters = false

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(key: "lastMessage", ascending: false),
						  NSSortDescriptor(key: "userNode.favorite", ascending: false),
						  NSSortDescriptor(key: "longName", ascending: true)],
		animation: .default)

	private var users: FetchedResults<UserEntity>
	@State var node: NodeInfoEntity?
	@State var selectedUserNum: Int64?
	@State private var userSelection: UserEntity? // Nothing selected by default.
	@State private var isPresentingDeleteUserMessagesConfirm: Bool = false

	var body: some View {
		let localeDateFormat = DateFormatter.dateFormat(fromTemplate: "yyMMdd", options: 0, locale: Locale.current)
		let dateFormatString = (localeDateFormat ?? "MM/dd/YY")
		VStack {
			List {
				if #available(iOS 17.0, macOS 14.0, *) {
					TipView(ContactsTip(), arrowEdge: .bottom)
				}
				ForEach(users) { (user: UserEntity) in
					let mostRecent = user.messageList.last
					let lastMessageTime = Date(timeIntervalSince1970: TimeInterval(Int64((mostRecent?.messageTimestamp ?? 0 ))))
					let lastMessageDay = Calendar.current.dateComponents([.day], from: lastMessageTime).day ?? 0
					let currentDay = Calendar.current.dateComponents([.day], from: Date()).day ?? 0
					if  user.num != bleManager.connectedPeripheral?.num ?? 0 {
						NavigationLink(destination: UserMessageList(user: user)) {
							ZStack {
								Image(systemName: "circle.fill")
									.opacity(user.unreadMessages > 0 ? 1 : 0)
									.font(.system(size: 10))
									.foregroundColor(.accentColor)
									.brightness(0.2)
							}

							CircleText(text: user.shortName ?? "?", color: Color(UIColor(hex: UInt32(user.num))))

							VStack(alignment: .leading) {
								HStack {
									Text(user.longName ?? "unknown".localized)
										.font(.headline)
									Spacer()
									if user.userNode?.favorite ?? false {
										Image(systemName: "star.fill")
											.foregroundColor(.yellow)
									}
									if user.messageList.count > 0 {
										if lastMessageDay == currentDay {
											Text(lastMessageTime, style: .time )
												.font(.footnote)
												.foregroundColor(.secondary)
										} else if lastMessageDay == (currentDay - 1) {
											Text("Yesterday")
												.font(.footnote)
												.foregroundColor(.secondary)
										} else if lastMessageDay < (currentDay - 1) && lastMessageDay > (currentDay - 5) {
											Text(lastMessageTime.formattedDate(format: dateFormatString))
												.font(.footnote)
												.foregroundColor(.secondary)
										} else if lastMessageDay < (currentDay - 1800) {
											Text(lastMessageTime.formattedDate(format: dateFormatString))
												.font(.footnote)
												.foregroundColor(.secondary)
										}
									}
								}

								if user.messageList.count > 0 {
									HStack(alignment: .top) {
										Text("\(mostRecent != nil ? mostRecent!.messagePayload! : " ")")
											.font(.footnote)
											.foregroundColor(.secondary)
									}
								}
							}
						}
						.frame(height: 62)
						.contextMenu {
							Button {

								if node != nil && !(user.userNode?.favorite ?? false) {
									let success = bleManager.setFavoriteNode(node: user.userNode!, connectedNodeNum: Int64(node!.num))
									if success {
										user.userNode?.favorite = !(user.userNode?.favorite ?? true)
										Logger.data.info("Favorited a node")
									}
								} else {
									let success = bleManager.removeFavoriteNode(node: user.userNode!, connectedNodeNum: Int64(node!.num))
									if success {
										user.userNode?.favorite = !(user.userNode?.favorite ?? true)
										Logger.data.info("Un Favorited a node")
									}
								}
								context.refresh(user, mergeChanges: true)
								do {
									try context.save()
								} catch {
									context.rollback()
									Logger.data.error("Save Node Favorite Error")
								}
							} label: {
								Label((user.userNode?.favorite ?? false)  ? "Un-Favorite" : "Favorite", systemImage: (user.userNode?.favorite ?? false) ? "star.slash.fill" : "star.fill")
							}
							Button {
								user.mute = !user.mute
								do {
									try context.save()
								} catch {
									context.rollback()
									Logger.data.error("Save User Mute Error")
								}
							} label: {
								Label(user.mute ? "Show Alerts" : "Hide Alerts", systemImage: user.mute ? "bell" : "bell.slash")
							}
							if user.messageList.count  > 0 {
								Button(role: .destructive) {
									isPresentingDeleteUserMessagesConfirm = true
									userSelection = user
								} label: {
									Label("Delete Messages", systemImage: "trash")
								}
							}
						}
						.confirmationDialog(
							"This conversation will be deleted.",
							isPresented: $isPresentingDeleteUserMessagesConfirm,
							titleVisibility: .visible
						) {
							Button(role: .destructive) {
								updateCoreDataController.deleteUserMessages(user: userSelection!)
								context.refresh(node!.user!, mergeChanges: true)
								UIApplication.shared.applicationIconBadgeNumber = appState.unreadChannelMessages + appState.unreadDirectMessages
							} label: {
								Text("delete")
							}
						}
					}
				}
			}
			.listStyle(.plain)
			.navigationTitle(String.localizedStringWithFormat("contacts %@".localized, String(users.count == 0 ? 0 : users.count - 1)))
			.sheet(isPresented: $isEditingFilters) {
				NodeListFilter(filterTitle: "Contact Filters", viaLora: $viaLora, viaMqtt: $viaMqtt, isOnline: $isOnline, isFavorite: $isFavorite, distanceFilter: $distanceFilter, maximumDistance: $maxDistance, hopsAway: $hopsAway, roleFilter: $roleFilter, deviceRoles: $deviceRoles)
			}
			.onChange(of: searchText) { _ in
				searchUserList()
			}
			.onChange(of: viaLora) { _ in
				if !viaLora && !viaMqtt {
					viaMqtt = true
				}
				searchUserList()
			}
			.onChange(of: viaMqtt) { _ in
				if !viaLora && !viaMqtt {
					viaLora = true
				}
				searchUserList()
			}
			.onChange(of: [deviceRoles]) { _ in
				searchUserList()
			}
			.onChange(of: hopsAway) { _ in
				searchUserList()
			}
			.onChange(of: isOnline) { _ in
				searchUserList()
			}
			.onChange(of: isFavorite) { _ in
				searchUserList()
			}
			.onChange(of: maxDistance) { _ in
				searchUserList()
			}
			.onChange(of: distanceFilter) { _ in
				searchUserList()
			}
			.onChange(of: selectedUserNum) { newUserNum in
				userSelection = users.first(where: { $0.num == newUserNum })
			}
			.onAppear {
				searchUserList()
			}
			.safeAreaInset(edge: .bottom, alignment: .trailing) {
				HStack {
					Button(action: {
						withAnimation {
							isEditingFilters = !isEditingFilters
						}
					}) {
						Image(systemName: !isEditingFilters ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
							.padding(.vertical, 5)
					}
					.tint(Color(UIColor.secondarySystemBackground))
					.foregroundColor(.accentColor)
					.buttonStyle(.borderedProminent)

				}
				.controlSize(.regular)
				.padding(5)
			}
			.padding(.bottom, 5)
			.searchable(text: $searchText, placement: users.count > 10 ? .navigationBarDrawer(displayMode: .always) : .automatic, prompt: "Find a contact")
				.disableAutocorrection(true)
				.scrollDismissesKeyboard(.immediately)
		}
	}

	private func searchUserList() {

		/// Case Insensitive Search Text Predicates
		let searchPredicates = ["userId", "numString", "hwModel", "longName", "shortName"].map { property in
			return NSPredicate(format: "%K CONTAINS[c] %@", property, searchText)
		}
		/// Create a compound predicate using each text search preicate as an OR
		let textSearchPredicate = NSCompoundPredicate(type: .or, subpredicates: searchPredicates)
		/// Create an array of predicates to hold our AND predicates
		var predicates: [NSPredicate] = []
		/// Mqtt
		if !(viaLora && viaMqtt) {
			if viaLora {
				let loraPredicate = NSPredicate(format: "userNode.viaMqtt == NO")
				predicates.append(loraPredicate)
			} else {
				let mqttPredicate = NSPredicate(format: "userNode.viaMqtt == YES")
				predicates.append(mqttPredicate)
			}
		}
		/// Roles
		if roleFilter && deviceRoles.count > 0 {
			var rolesArray: [NSPredicate] = []
			for dr in deviceRoles {
				let deviceRolePredicate = NSPredicate(format: "role == %i", Int32(dr))
				rolesArray.append(deviceRolePredicate)
			}
			let compoundPredicate = NSCompoundPredicate(type: .or, subpredicates: rolesArray)
			predicates.append(compoundPredicate)
		}
		/// Hops Away
		if hopsAway == 0.0 {
			let hopsAwayPredicate = NSPredicate(format: "userNode.hopsAway == %i", Int32(hopsAway))
			predicates.append(hopsAwayPredicate)
		} else if hopsAway > -1.0 {
			let hopsAwayPredicate = NSPredicate(format: "userNode.hopsAway > 0 AND userNode.hopsAway <= %i", Int32(hopsAway))
			predicates.append(hopsAwayPredicate)
		}
		/// Online
		if isOnline {
			let isOnlinePredicate = NSPredicate(format: "userNode.lastHeard >= %@", Calendar.current.date(byAdding: .minute, value: -15, to: Date())! as NSDate)
			predicates.append(isOnlinePredicate)
		}
		/// Favorites
		if isFavorite {
			let isFavoritePredicate = NSPredicate(format: "userNode.favorite == YES")
			predicates.append(isFavoritePredicate)
		}
		/// Distance
		if distanceFilter {
			let pointOfInterest = LocationHelper.currentLocation

			if pointOfInterest.latitude != LocationHelper.DefaultLocation.latitude && pointOfInterest.longitude != LocationHelper.DefaultLocation.longitude {
				let d: Double = maxDistance * 1.1
				let r: Double = 6371009
				let meanLatitidue = pointOfInterest.latitude * .pi / 180
				let deltaLatitude = d / r * 180 / .pi
				let deltaLongitude = d / (r * cos(meanLatitidue)) * 180 / .pi
				let minLatitude: Double = pointOfInterest.latitude - deltaLatitude
				let maxLatitude: Double = pointOfInterest.latitude + deltaLatitude
				let minLongitude: Double = pointOfInterest.longitude - deltaLongitude
				let maxLongitude: Double = pointOfInterest.longitude + deltaLongitude
				let distancePredicate = NSPredicate(format: "(SUBQUERY(userNode.positions, $position, $position.latest == TRUE && (%lf <= ($position.longitudeI / 1e7)) AND (($position.longitudeI / 1e7) <= %lf) AND (%lf <= ($position.latitudeI / 1e7)) AND (($position.latitudeI / 1e7) <= %lf))).@count > 0", minLongitude, maxLongitude, minLatitude, maxLatitude)
				predicates.append(distancePredicate)
			}
		}

		if predicates.count > 0 || !searchText.isEmpty {
			if !searchText.isEmpty {
				let filterPredicates = NSCompoundPredicate(type: .and, subpredicates: predicates)
				users.nsPredicate = NSCompoundPredicate(type: .and, subpredicates: [textSearchPredicate, filterPredicates])
			} else {
				users.nsPredicate = NSCompoundPredicate(type: .and, subpredicates: predicates)
			}
		} else {
			users.nsPredicate = nil
		}
	}
}
