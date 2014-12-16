# Author: Ritchie Lee, ritchie.lee@sv.cmu.reduce
# Date: 12/15/2014


module EncounterDBN

export
    AbstractEncounterDBN,
    AddObserver,

    getInitialSample,
    initialize,
    step,
    get,

    CorrAEMDBN


using AbstractEncounterDBNImpl

using CorrAEMDBNImpl

end


