import Branch
import BranchEnvironment
import Combine
import ComposableArchitecture
import LogEnvironment
import NonEmpty
import Tagged
import Types
import Utility
import Validated


public extension BranchEnvironment {
  static let live = BranchEnvironment(
    subscribeToDeepLinks: {
      Effect.run { subscriber in
        logEffect("subscribeToDeepLinks")
        Branch
          .getInstance()
          .initSession(
            launchOptions: nil,
            andRegisterDeepLinkHandler: handleBranchCallback(subscriber.send)
          )
        return AnyCancellable {}
      }
    },
    handleDeepLink: { url in
      .fireAndForget {
        logEffect("handleDeepLink")
        Branch
          .getInstance()
          .handleDeepLink(url)
      }
    }
  )
}

func handleBranchCallback(
  _ f: @escaping (Validated<DeepLink, NonEmptyString>) -> Void
) -> ([AnyHashable : Any]?, Error?) -> Void {
  { params, error in
    logEffect("subscribeToDeepLinks.handleBranchCallback Params: \(String(describing: params)) Error: \(String(describing: error))")
    
    guard error == nil else {
      f(.error("Branch error: \(error!.localizedDescription)"))
      return
    }
    
    if let params = params {
      if clickedBranchLink(params) {
        f(validate(deepLink: params))
      }
    } else {
      f(.error("Branch callback returned nither error nor parameters"))
    }
  }
}

func validate(deepLink params: [AnyHashable: Any]) -> Validated<DeepLink, NonEmptyString> {
  zip(with: DeepLink.init)(
    validate(key: "publishable_key", in: params, has: PublishableKey.self),
    validate(variant: params)
  )
}

// Not a Monad, because it doesn't accumulate the results
extension Validated {
  func flatMap<OtherValue>(_ f: (Value) -> Validated<OtherValue, Error>) -> Validated<OtherValue, Error> {
    switch self {
    case let .valid(value):   return f(value)
    case let .invalid(error): return .invalid(error)
    }
  }
}

func validate(key: NonEmptyString, existsIn params: [AnyHashable: Any]) -> Validated<Any, NonEmptyString> {
  params[key.rawValue].map(Validated.valid)
    ?? .error("Didn't found \(key) key in the deep link")
}

func validate<T>(key: NonEmptyString, value: Any, isOfType type: T.Type) -> Validated<T, NonEmptyString> {
  (value as? T).map(Validated.valid)
    ?? .error("\(key)'s value is not a \(type)")
}


func validate(key: NonEmptyString, valueIsNonEmptyString string: String) -> Validated<NonEmptyString, NonEmptyString> {
  NonEmptyString(rawValue: string).map(Validated.valid)
    ?? .error("\(key) is empty")
}

func validate(variant params: [AnyHashable: Any]) -> Validated<DeepLink.Variant, NonEmptyString> {
  
  let driverID = validate(key: driverIDKey, in: params, has: DriverID.self)
  let email = validate(key: emailKey, in: params, has: Email.self)
  let phoneNumber = validate(key: "phone_number", in: params, has: PhoneNumber.self)
  let metadata = validate(key: metadataKey, existsIn: params).flatMap(validate(metadata:))
  
  switch (email, phoneNumber, metadata, driverID) {
  case let (.valid(email), .valid(phoneNumber), .valid(metadata), _):  return .valid(.new(.both(email, phoneNumber), metadata))
  case let (.valid(email), .valid(phoneNumber), _, _):                 return .valid(.new(.both(email, phoneNumber), [:]))
  case let (.invalid, .valid(phoneNumber), .valid(metadata), _):       return .valid(.new(.that(phoneNumber), metadata))
  case let (.invalid, .valid(phoneNumber), _, _):                      return .valid(.new(.that(phoneNumber), [:]))
  case let (.valid(email), _, .valid(metadata), _):                    return .valid(.new(.this(email), metadata))
  case let (.valid(email), _, _, _):                                   return .valid(.new(.this(email), [:]))
  case let (_, _, _, .valid(driverID)):                                return .valid(.old(driverID))
  case let (.invalid(emailE), .invalid(phoneNumberE), _, .invalid(driverIDE)):
    return .invalid(.init("Deep link doesn't have valid email or phone_number or driver_id") + emailE + phoneNumberE + driverIDE)
  }
}

func validate(metadata value: Any) -> Validated<JSON.Object, NonEmptyString> {
  do {
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    let json = try JSONDecoder().decode(JSON.self, from: data)
    
    guard case let .object(object) = json else { return .error("Expected metadata to be a JSON object") }
    
    for key in object.keys {
      guard key != emailKey.rawValue && key != "phone_number" else { return .error("Metadata shouldn't contain email and phone_number keys") }
    }
    
    return .valid(object)
  } catch {
    return .error("Failed to parse metadata dictionary as JSON: \(error.localizedDescription)")
  }
}

let metadataKey: NonEmptyString = "metadata"
let emailKey: NonEmptyString = "email"
let driverIDKey: NonEmptyString = "driver_id"

func validate<T>(
  key: NonEmptyString,
  in params: [AnyHashable: Any],
  has type: Tagged<T, NonEmptyString>.Type
) -> Validated<Tagged<T, NonEmptyString>, NonEmptyString> {
  validate(key: key, existsIn: params)
    .flatMap { validate(key: key, value: $0, isOfType: String.self) }
    .flatMap(key |> curry(validate(key:valueIsNonEmptyString:)))
    .map(Tagged<T, NonEmptyString>.init(rawValue:))
}

func clickedBranchLink(_ params: [AnyHashable: Any]) -> Bool {
  (params["+clicked_branch_link"] as? NSNumber).map(\.boolValue) ?? false
}
