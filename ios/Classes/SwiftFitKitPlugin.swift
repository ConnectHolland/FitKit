import Flutter
import UIKit
import HealthKit

public class SwiftFitKitPlugin: NSObject, FlutterPlugin {

    private let TAG = "FitKit";

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "fit_kit", binaryMessenger: registrar.messenger())
        let instance = SwiftFitKitPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private var healthStore: HKHealthStore? = nil;

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard HKHealthStore.isHealthDataAvailable() else {
            result(FlutterError(code: TAG, message: "Not supported", details: nil))
            return
        }

        if (healthStore == nil) {
            healthStore = HKHealthStore();
        }

        do {
            if (call.method == "hasPermissions") {
                let request = try PermissionsRequest.fromCall(call: call)
                hasPermissions(request: request, result: result)
            } else if (call.method == "requestPermissions") {
                let request = try PermissionsRequest.fromCall(call: call)
                requestPermissions(request: request, result: result)
            } else if (call.method == "revokePermissions") {
                revokePermissions(result: result)
            } else if (call.method == "read") {
                let request = try ReadRequest.fromCall(call: call)
                read(request: request, result: result)
            } else {
                result(FlutterMethodNotImplemented)
            }
        } catch {
            result(FlutterError(code: TAG, message: "Error \(error)", details: nil))
        }
    }


    /**
    * On iOS you can only know if user has responded to request access screen.
    * Not possible to tell if he has allowed access to read.
    *
    *   # getRequestStatusForAuthorization #
    *   If "status == unnecessary" means if requestAuthorization will be called request access screen will not be shown.
    *   So user has already responded to request access screen and kinda has permissions.
    *
    *   # authorizationStatus #
    *   If "status == notDetermined" user has not responded to request access screen.
    *   Once he responds no matter of the result status will be sharingDenied.
    */
    private func hasPermissions(request: PermissionsRequest, result: @escaping FlutterResult) {
        if #available(iOS 12.0, *) {
            healthStore!.getRequestStatusForAuthorization(toShare: [], read: Set(request.sampleTypes)) { (status, error) in
                guard error == nil else {
                    result(FlutterError(code: self.TAG, message: "hasPermissions", details: error))
                    return
                }

                guard status == HKAuthorizationRequestStatus.unnecessary else {
                    result(false)
                    return
                }

                result(true)
            }
        } else {
            let authorized = request.sampleTypes.map {
                        healthStore!.authorizationStatus(for: $0)
                    }
                    .allSatisfy {
                        $0 != HKAuthorizationStatus.notDetermined
                    }
            result(authorized)
        }
    }

    private func requestPermissions(request: PermissionsRequest, result: @escaping FlutterResult) {
        requestAuthorization(sampleTypes: request.sampleTypes) { success, error in
            guard success else {
                result(false)
                return
            }

            result(true)
        }
    }

    /**
    * Not supported by HealthKit.
    */
    private func revokePermissions(result: @escaping FlutterResult) {
        result(nil)
    }

    private func read(request: ReadRequest, result: @escaping FlutterResult) {
        requestAuthorization(sampleTypes: [request.sampleType]) { success, error in
            guard success else {
                result(error)
                return
            }

            self.readSample(request: request, result: result)
        }
    }

    private func requestAuthorization(sampleTypes: Array<HKSampleType>, completion: @escaping (Bool, FlutterError?) -> Void) {
        healthStore!.requestAuthorization(toShare: nil, read: Set(sampleTypes)) { (success, error) in
            guard success else {
                completion(false, FlutterError(code: self.TAG, message: "Error \(error?.localizedDescription ?? "empty")", details: nil))
                return
            }

            completion(true, nil)
        }
    }

    private func readSample(request: ReadRequest, result: @escaping FlutterResult) {
        print("readSample: \(request.type)")

        let predicate = HKQuery.predicateForSamples(withStart: request.dateFrom, end: request.dateTo, options: .strictStartDate)
        
        let query: HKQuery
        if let quantityType = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: request.sampleType.identifier)) {
            query = createStatisticsQuery(request: request, quantityType: quantityType, predicate: predicate, result: result)
        } else {
            query = createSampleQuery(request: request, predicate: predicate, result: result)
        }
        
        healthStore!.execute(query)
    }

    private func readValue(sample: HKSample, unit: HKUnit) -> Any {
        if let sample = sample as? HKQuantitySample {
            return sample.quantity.doubleValue(for: unit)
        } else if let sample = sample as? HKCategorySample {
            return sample.value
        }

        return -1
    }
    
    private func readStatisticsValue(statistics: HKStatistics, unit: HKUnit) -> Any {
        if let quantity = statistics.sumQuantity() {
            return quantity.doubleValue(for: unit)
        }
        
        return -1
    }

    private func readSource(sample: HKSample) -> String {
        if #available(iOS 9, *) {
            return sample.sourceRevision.source.name;
        }

        return sample.source.name;
    }
    
    private func readProductType(sample: HKSample) -> String {
        if #available(iOS 11, *) {
            return sample.sourceRevision.productType ?? "";
        }

        return "";
    }
    
    private func createSampleQuery(request: ReadRequest, predicate: NSPredicate, result: @escaping FlutterResult) -> HKSampleQuery {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: request.limit == nil)
        
        let query = HKSampleQuery(sampleType: request.sampleType, predicate: predicate, limit: request.limit ?? HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) {
            _, samplesOrNil, error in

            guard var samples = samplesOrNil else {
                result(FlutterError(code: self.TAG, message: "Results are null", details: error))
                return
            }

            if (request.limit != nil) {
                // if limit is used sort back to ascending
                samples = samples.sorted(by: { $0.startDate.compare($1.startDate) == .orderedAscending })
            }

            print(samples)
            result(samples.map { sample -> NSDictionary in
                [
                    "value": self.readValue(sample: sample, unit: request.unit),
                    "date_from": Int(sample.startDate.timeIntervalSince1970 * 1000),
                    "date_to": Int(sample.endDate.timeIntervalSince1970 * 1000),
                    "source": self.readSource(sample: sample),
                    "user_entered": sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true,
                    "product_type": self.readProductType(sample: sample),
                ]
            })
        }
        return query
    }
    
    private func createStatisticsQuery(request: ReadRequest, quantityType: HKQuantityType, predicate: NSPredicate, result: @escaping FlutterResult) -> HKStatisticsQuery {
        
        let statisticsQuery = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: .cumulativeSum) {
            _, statisticsOrNil, error in
            guard let statistics = statisticsOrNil else {
                result(FlutterError(code: self.TAG, message: "Results are null", details: error))
                return
            }
            
            result(
                [
                    "value": self.readStatisticsValue(statistics: statistics, unit: request.unit),
                    "date_from": Int(statistics.startDate.timeIntervalSince1970 * 1000),
                    "date_to": Int(statistics.endDate.timeIntervalSince1970 * 1000),
                    // TODO: HKStatistics contains array of sources. Discuss what to return here. For now, just return empty string.
                    "source": "",
                    // TODO: Probably can be removed.
                    "user_entered": false,
                    // TODO: Remove ProductType
                    "product_type": ""
                ]
            )
            
        }
        
        return statisticsQuery
        
    }
}
