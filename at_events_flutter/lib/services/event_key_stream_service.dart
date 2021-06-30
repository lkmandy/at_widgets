import 'dart:async';
import 'dart:convert';

import 'package:at_client_mobile/at_client_mobile.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_contact/at_contact.dart';
import 'package:at_events_flutter/at_events_flutter.dart';
import 'package:at_events_flutter/models/event_key_location_model.dart';
import 'package:at_events_flutter/models/event_notification.dart';
import 'package:at_events_flutter/services/at_event_notification_listener.dart';
import 'package:at_events_flutter/services/sync_secondary.dart';
import 'package:at_events_flutter/utils/constants.dart';
import 'package:at_location_flutter/location_modal/location_notification.dart';
import 'package:latlong/latlong.dart';

import 'contact_service.dart';

class EventKeyStreamService {
  EventKeyStreamService._();
  static final EventKeyStreamService _instance = EventKeyStreamService._();
  factory EventKeyStreamService() => _instance;

  AtClientImpl atClientInstance;
  AtContactsImpl atContactImpl;
  AtContact loggedInUserDetails;
  List<EventKeyLocationModel> allEventNotifications = [],
      allPastEventNotifications = [];
  String currentAtSign;
  List<AtContact> contactList = [];

  // ignore: close_sinks
  StreamController atNotificationsController =
      StreamController<List<EventKeyLocationModel>>.broadcast();
  Stream<List<EventKeyLocationModel>> get atNotificationsStream =>
      atNotificationsController.stream as Stream<List<EventKeyLocationModel>>;
  StreamSink<List<EventKeyLocationModel>> get atNotificationsSink =>
      atNotificationsController.sink as StreamSink<List<EventKeyLocationModel>>;

  Function(List<EventKeyLocationModel>) streamAlternative;

  void init(AtClientImpl clientInstance,
      {Function(List<EventKeyLocationModel>) streamAlternative}) async {
    loggedInUserDetails = null;
    atClientInstance = clientInstance;
    currentAtSign = atClientInstance.currentAtSign;
    allEventNotifications = [];
    this.streamAlternative = streamAlternative;

    atNotificationsController =
        StreamController<List<EventKeyLocationModel>>.broadcast();
    getAllEventNotifications();

    loggedInUserDetails = await getAtSignDetails(currentAtSign);
    getAllContactDetails(currentAtSign);
  }

  void getAllContactDetails(String currentAtSign) async {
    atContactImpl = await AtContactsImpl.getInstance(currentAtSign);
    contactList = await atContactImpl.listContacts();
  }

  void getAllEventNotifications() async {
    var response = await atClientInstance.getKeys(
      regex: 'createevent-',
    );

    if (response.isEmpty) {
      // TODO:
      //   SendLocationNotification().init(atClientInstance);
      return;
    }

    response.forEach((key) {
      var eventKeyLocationModel = EventKeyLocationModel(key: key);
      allEventNotifications.add(eventKeyLocationModel);
    });

    allEventNotifications.forEach((notification) {
      var atKey = EventService().getAtKey(notification.key);
      notification.atKey = atKey;
    });

    // TODO
    // filterBlockedContactsforEvents();

    for (var i = 0; i < allEventNotifications.length; i++) {
      AtValue value = await getAtValue(allEventNotifications[i].atKey);
      if (value != null) {
        allEventNotifications[i].atValue = value;
      }
    }

    convertJsonToEventModel();
    filterPastEventsFromList();

    await checkForPendingEvents();

    // ignore: unawaited_futures
    updateEventDataAccordingToAcknowledgedData();
  }

  void convertJsonToEventModel() {
    var tempRemoveEventArray = <EventKeyLocationModel>[];

    for (var i = 0; i < allEventNotifications.length; i++) {
      try {
        // ignore: unrelated_type_equality_checks
        if (allEventNotifications[i].atValue != 'null' &&
            allEventNotifications[i].atValue != null) {
          var event = EventNotificationModel.fromJson(
              jsonDecode(allEventNotifications[i].atValue.value));

          if (event != null && event.group.members.isNotEmpty) {
            event.key = allEventNotifications[i].key;

            allEventNotifications[i].eventNotificationModel = event;
          }
        } else {
          tempRemoveEventArray.add(allEventNotifications[i]);
        }
      } catch (e) {
        tempRemoveEventArray.add(allEventNotifications[i]);
      }
    }

    allEventNotifications
        .removeWhere((element) => tempRemoveEventArray.contains(element));
  }

  void filterPastEventsFromList() {
    for (var i = 0; i < allEventNotifications.length; i++) {
      if (allEventNotifications[i]
              .eventNotificationModel
              .event
              .endTime
              .difference(DateTime.now())
              .inMinutes <
          0) allPastEventNotifications.add(allEventNotifications[i]);
    }

    allEventNotifications
        .removeWhere((element) => allPastEventNotifications.contains(element));
  }

  Future<void> checkForPendingEvents() async {
    allEventNotifications.forEach((notification) async {
      notification.eventNotificationModel.group.members.forEach((member) async {
        if ((member.atSign == currentAtSign) &&
            (member.tags['isAccepted'] == false) &&
            (member.tags['isExited'] == false)) {
          var atkeyMicrosecondId =
              notification.key.split('createevent-')[1].split('@')[0];
          var acknowledgedKeyId = 'eventacknowledged-$atkeyMicrosecondId';
          var allRegexResponses =
              await atClientInstance.getKeys(regex: acknowledgedKeyId);
          // ignore: prefer_is_empty
          if ((allRegexResponses != null) && (allRegexResponses.length > 0)) {
            notification.haveResponded = true;
          }
        }
      });
    });
  }

  Future<void> updateEventDataAccordingToAcknowledgedData() async {
    // var allEventKey = await atClientInstance.getKeys(
    //   regex: 'createevent-',
    // );

    // if (allEventKey.isEmpty) {
    //   return;
    // }

    var allRegexResponses = [], allEventUserLocationResponses = [];
    for (var i = 0; i < allEventNotifications.length; i++) {
      allRegexResponses = [];
      allEventUserLocationResponses = [];
      var eventUserLocation = <EventUserLocation>[];
      var atkeyMicrosecondId =
          allEventNotifications[i].key.split('createevent-')[1].split('@')[0];

      /// For location update
      var updateEventLocationKeyId = 'updateeventlocation-$atkeyMicrosecondId';

      allEventUserLocationResponses =
          await atClientInstance.getKeys(regex: updateEventLocationKeyId);

      if (allEventUserLocationResponses.isNotEmpty) {
        for (var j = 0; j < allEventUserLocationResponses.length; j++) {
          if (allEventUserLocationResponses[j] != null &&
              !allEventNotifications[i].key.contains('cached')) {
            // TODO: Now we'll send some other data, this model will change
            var eventData =
                await geteventData(allEventUserLocationResponses[j]);

            if (eventData != null) {
              eventUserLocation.add(eventData);
            }
          }
        }
      }

      ///

      var acknowledgedKeyId = 'eventacknowledged-$atkeyMicrosecondId';
      allRegexResponses =
          await atClientInstance.getKeys(regex: acknowledgedKeyId);

      if (allRegexResponses.isNotEmpty) {
        for (var j = 0; j < allRegexResponses.length; j++) {
          if (allRegexResponses[j] != null &&
              !allEventNotifications[i].key.contains('cached')) {
            var acknowledgedAtKey =
                EventService().getAtKey(allRegexResponses[j]);
            var createEventAtKey =
                EventService().getAtKey(allEventNotifications[i].key);

            var result = await atClientInstance
                .get(acknowledgedAtKey)
                // ignore: return_of_invalid_type_from_catch_error
                .catchError((e) => print('error in get $e'));

            if ((result == null) || (result.value == null)) {
              continue;
            }

            var acknowledgedEvent =
                EventNotificationModel.fromJson(jsonDecode(result.value));
            var storedEvent = EventNotificationModel();

            storedEvent = allEventNotifications[i].eventNotificationModel;

            /// Update acknowledgedEvent location with updated latlng

            acknowledgedEvent.group.members.forEach((member) {
              var indexWhere = eventUserLocation
                  .indexWhere((e) => e.atsign == member.atSign);

              if (acknowledgedAtKey.sharedBy[0] != '@') {
                acknowledgedAtKey.sharedBy = '@' + acknowledgedAtKey.sharedBy;
              }

              if (indexWhere > -1 &&
                  eventUserLocation[indexWhere].atsign ==
                      acknowledgedAtKey.sharedBy) {
                member.tags['lat'] =
                    eventUserLocation[indexWhere].latLng.latitude;
                member.tags['long'] =
                    eventUserLocation[indexWhere].latLng.longitude;
              }
            });

            ///

            if (!compareEvents(storedEvent, acknowledgedEvent)) {
              storedEvent.isUpdate = true;

              storedEvent.group.members.forEach((groupMember) {
                acknowledgedEvent.group.members.forEach((element) {
                  if (groupMember.atSign.toLowerCase() ==
                          element.atSign.toLowerCase() &&
                      groupMember.atSign.contains(acknowledgedAtKey.sharedBy)) {
                    groupMember.tags = element.tags;
                  }
                });
              });

              var allAtsignList = <String>[];
              storedEvent.group.members.forEach((element) {
                allAtsignList.add(element.atSign);
              });

              /// To let other puts complete
              // await Future.delayed(Duration(seconds: 5));
              var updateResult =
                  await updateEvent(storedEvent, createEventAtKey);

              createEventAtKey.sharedWith = jsonEncode(allAtsignList);

              await SyncSecondary().callSyncSecondary(SyncOperation.notifyAll,
                  atKey: createEventAtKey,
                  notification:
                      EventNotificationModel.convertEventNotificationToJson(
                          storedEvent),
                  operation: OperationEnum.update,
                  isDedicated: MixedConstants.isDedicated);

              if (updateResult is bool && updateResult == true) {
                mapUpdatedEventDataToWidget(storedEvent);
              }
            }
            // }
            // }
          }
        }
      }
    }
  }

  void mapUpdatedEventDataToWidget(EventNotificationModel eventData,
      {Map<dynamic, dynamic> tags,
      String tagOfAtsign,
      bool updateLatLng = false,
      bool updateOnlyCreator = false}) {
    String neweventDataKeyId;
    neweventDataKeyId =
        eventData.key.split('${MixedConstants.CREATE_EVENT}-')[1].split('@')[0];

    for (var i = 0; i < allEventNotifications.length; i++) {
      if (allEventNotifications[i].key.contains(neweventDataKeyId)) {
        /// if we want to update everything
        // allEventNotifications[i].eventNotificationModel = eventData;

        /// For events send tags of group members if we have and update only them
        if (updateOnlyCreator) {
          /// So that creator doesnt update group details
          eventData.group =
              allEventNotifications[i].eventNotificationModel.group;
        }

        if ((tags != null) && (tagOfAtsign != null)) {
          allEventNotifications[i]
              .eventNotificationModel
              .group
              .members
              .where((element) => element.atSign == tagOfAtsign)
              .forEach((element) {
            if (updateLatLng) {
              element.tags['lat'] = tags['lat'];
              element.tags['long'] = tags['long'];
            } else {
              element.tags = tags;
            }
          });
        } else {
          allEventNotifications[i].eventNotificationModel = eventData;
        }

        allEventNotifications[i].eventNotificationModel.key =
            allEventNotifications[i].key;

        /// TODO: Update the map screen, with common components
        // LocationService().updateEventWithNewData(
        //     allHybridNotifications[i].eventNotificationModel);
      }
    }
    notifyListeners();

    /// TODO: To Update location sharing
    // if ((eventData.isSharing) && (eventData.isAccepted)) {
    //   if (eventData.atsignCreator == currentAtSign) {
    //     SendLocationNotification().addMember(eventData);
    //   }
    // } else {
    //   SendLocationNotification().removeMember(eventData.key);
    // }
  }

  Future<dynamic> updateEvent(
      EventNotificationModel eventData, AtKey key) async {
    try {
      var notification =
          EventNotificationModel.convertEventNotificationToJson(eventData);

      var result = await atClientInstance.put(key, notification,
          isDedicated: MixedConstants.isDedicated);
      if (result is bool) {
        if (result) {
          if (MixedConstants.isDedicated) {
            await SyncSecondary()
                .callSyncSecondary(SyncOperation.syncSecondary);
          }
        }
        print('event acknowledged:$result');
        return result;
      } else if (result != null) {
        return result.toString();
      } else {
        return result;
      }
    } catch (e) {
      print('error in updating notification:$e');
      return false;
    }
  }

  Future<void> actionOnEvent(
      EventNotificationModel event, ATKEY_TYPE_ENUM keyType,
      {bool isAccepted, bool isSharing, bool isExited}) async {
    var eventData = EventNotificationModel.fromJson(jsonDecode(
        EventNotificationModel.convertEventNotificationToJson(event)));

    try {
      var atkeyMicrosecondId =
          eventData.key.split('createevent-')[1].split('@')[0];

      var currentAtsign =
          AtEventNotificationListener().atClientInstance.currentAtSign;

      eventData.isUpdate = true;
      if (eventData.atsignCreator.toLowerCase() ==
          currentAtsign.toLowerCase()) {
        eventData.isSharing =
            // ignore: prefer_if_null_operators
            isSharing != null ? isSharing : eventData.isSharing;
        if (isSharing == false) {
          eventData.lat = null;
          eventData.long = null;
        }
      } else {
        eventData.group.members.forEach((member) {
          if (member.atSign[0] != '@') member.atSign = '@' + member.atSign;
          if (currentAtsign[0] != '@') currentAtsign = '@' + currentAtsign;
          if (member.atSign.toLowerCase() == currentAtsign.toLowerCase()) {
            member.tags['isAccepted'] =
                // ignore: prefer_if_null_operators
                isAccepted != null ? isAccepted : member.tags['isAccepted'];
            member.tags['isSharing'] =
                // ignore: prefer_if_null_operators
                isSharing != null ? isSharing : member.tags['isSharing'];
            member.tags['isExited'] =
                // ignore: prefer_if_null_operators
                isExited != null ? isExited : member.tags['isExited'];

            if (isSharing == false || isExited == true) {
              member.tags['lat'] = null;
              member.tags['long'] = null;
            }

            if (isExited == true) {
              member.tags['isAccepted'] = false;
              member.tags['isSharing'] = false;
            }
          }
        });
      }

      var key = formAtKey(keyType, atkeyMicrosecondId, eventData.atsignCreator,
          currentAtsign, event);

      // TODO : Check whther key is correct
      print('key $key');

      var notification =
          EventNotificationModel.convertEventNotificationToJson(eventData);
      var result = await atClientInstance.put(key, notification,
          isDedicated: MixedConstants.isDedicated);

      print('actionOnEvent put = $result');

      if (MixedConstants.isDedicated) {
        await SyncSecondary().callSyncSecondary(SyncOperation.syncSecondary);
      }
      // if key type is createevent, we have to notify all members
      if (keyType == ATKEY_TYPE_ENUM.CREATEEVENT) {
        /// TODO: check, added without testing
        mapUpdatedEventDataToWidget(eventData);

        var allAtsignList = <String>[];
        eventData.group.members.forEach((element) {
          allAtsignList.add(element.atSign);
        });

        key.sharedWith = jsonEncode(allAtsignList);
        await SyncSecondary().callSyncSecondary(
          SyncOperation.notifyAll,
          atKey: key,
          notification: notification,
          operation: OperationEnum.update,
          isDedicated: MixedConstants.isDedicated,
        );
      } else {
        /// TODO: update pending status is receiver, add more if checks like already responded
        if (result) {
          updatePendingStatus(eventData);
        }
      }

      return result;
    } catch (e) {
      print('error in updating event $e');
      return false;
    }
  }

  void updatePendingStatus(EventNotificationModel notificationModel) async {
    for (var i = 0; i < allEventNotifications.length; i++) {
      allEventNotifications[i].haveResponded = true;
    }
  }

  // ignore: missing_return
  AtKey formAtKey(ATKEY_TYPE_ENUM keyType, String atkeyMicrosecondId,
      String sharedWith, String sharedBy, EventNotificationModel eventData) {
    switch (keyType) {
      case ATKEY_TYPE_ENUM.CREATEEVENT:
        AtKey atKey;

        /// TODO: Was in main app, uncomment if error
        // List<HybridNotificationModel> allEventsNotfication =
        //     HomeEventService().getAllEvents;
        // allEventsNotfication.forEach((event) {
        //   if (event.notificationType == NotificationType.Event &&
        //       event.key == eventData.key) {
        //     atKey = EventService().getAtKey(event.key);
        //   }
        // });
        atKey = EventService().getAtKey(eventData.key);
        return atKey;
        break;

      case ATKEY_TYPE_ENUM.ACKNOWLEDGEEVENT:
        var key = AtKey()
          ..metadata = Metadata()
          ..metadata.ttr = -1
          ..metadata.ccd = true
          ..sharedWith = sharedWith
          ..sharedBy = sharedBy;

        key.key = 'eventacknowledged-$atkeyMicrosecondId';
        return key;
        break;
    }
  }

  Future<dynamic> geteventData(String regex) async {
    var acknowledgedAtKey = EventService().getAtKey(regex);

    var result = await atClientInstance
        .get(acknowledgedAtKey)
        // ignore: return_of_invalid_type_from_catch_error
        .catchError((e) => print('error in get $e'));

    if ((result == null) || (result.value == null)) {
      return;
    }

    var eventData =
        LocationNotificationModel.fromJson(jsonDecode(result.value));
    var obj = EventUserLocation(eventData.atsignCreator, eventData.getLatLng);

    return obj;
  }

  bool compareEvents(
      EventNotificationModel eventOne, EventNotificationModel eventTwo) {
    var isDataSame = true;

    eventOne.group.members.forEach((groupOneMember) {
      eventTwo.group.members.forEach((groupTwoMember) {
        if (groupOneMember.atSign == groupTwoMember.atSign) {
          if (groupOneMember.tags['isAccepted'] !=
                  groupTwoMember.tags['isAccepted'] ||
              groupOneMember.tags['isSharing'] !=
                  groupTwoMember.tags['isSharing'] ||
              groupOneMember.tags['isExited'] !=
                  groupTwoMember.tags['isExited'] ||
              groupOneMember.tags['lat'] != groupTwoMember.tags['lat'] ||
              groupOneMember.tags['long'] != groupTwoMember.tags['long']) {
            isDataSame = false;
          }
        }
      });
    });

    return isDataSame;
  }

  Future<dynamic> getAtValue(AtKey key) async {
    try {
      var atvalue = await atClientInstance
          .get(key)
          // ignore: return_of_invalid_type_from_catch_error
          .catchError((e) => print('error in in key_stream_service get $e'));

      if (atvalue != null) {
        return atvalue;
      } else {
        return null;
      }
    } catch (e) {
      print('error in key_stream_service getAtValue:$e');
      return null;
    }
  }

  void notifyListeners() {
    if (streamAlternative != null) {
      streamAlternative(allEventNotifications);
    }
    atNotificationsSink.add(allEventNotifications);
  }
}

class EventUserLocation {
  String atsign;
  LatLng latLng;

  EventUserLocation(this.atsign, this.latLng);
}
