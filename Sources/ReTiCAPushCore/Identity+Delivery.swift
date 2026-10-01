import Foundation
import ReTiCA

public extension Identity {
    /// Our `lxmf.delivery` destination hash: what a push hub registers and what pushed DATA
    /// packets are addressed to. Same derivation as `LXMFNode.registerDelivery`.
    var lxmfDeliveryHash: Data { LXMessage.deliveryHash(identityHash: hash) }
}
