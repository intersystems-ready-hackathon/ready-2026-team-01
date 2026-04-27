Class Sample.FHIRSetup Extends %RegisteredObject
{

Parameter Namespace = "FHIRSERVER";

Parameter Endpoint = "/csp/healthshare/fhirserver/fhir/r4";

Parameter HospitalDataPath = "/home/irisowner/fhir-data/hospital";

Parameter PractitionerDataPath = "/home/irisowner/fhir-data/practitioner";

Parameter PatientDataPath = "/home/irisowner/fhir-data/patients";

Parameter StrategyClass = "HS.FHIRServer.Storage.JsonAdvSQL.InteractionsStrategy";

Parameter CorePackage = "hl7.fhir.r4.core@4.0.1";

ClassMethod Run() As %Status
{
    New $Namespace
    If '##class(%Dictionary.CompiledClass).%ExistsId("HS.FHIRServer.Installer") {
        Quit $$$ERROR($$$GeneralError, "FHIR installer classes are not available. Use an IRIS for Health image.")
    }

    If '##class(%File).DirectoryExists(..#HospitalDataPath) {
        Quit $$$ERROR($$$GeneralError, "FHIR hospital data directory does not exist: "_..#HospitalDataPath)
    }
    If '##class(%File).DirectoryExists(..#PractitionerDataPath) {
        Quit $$$ERROR($$$GeneralError, "FHIR practitioner data directory does not exist: "_..#PractitionerDataPath)
    }
    If '##class(%File).DirectoryExists(..#PatientDataPath) {
        Quit $$$ERROR($$$GeneralError, "FHIR patient data directory does not exist: "_..#PatientDataPath)
    }

    Write "Creating FHIR foundation namespace "_..#Namespace, !
    Set sc = ##class(HS.Util.Installer.Foundation).Install(..#Namespace)
    If $$$ISERR(sc) Quit sc

    Set $Namespace = ..#Namespace

    Write "Installing FHIR endpoint "_..#Endpoint, !
    Set packages = $ListBuild(..#CorePackage)
    Do ##class(HS.FHIRServer.Installer).InstallInstance(..#Endpoint, ..#StrategyClass, packages)

    Write "Loading FHIR hospital resources from "_..#HospitalDataPath, !
    Set sc = ##class(HS.FHIRServer.Tools.DataLoader).SubmitResourceFiles(..#HospitalDataPath, "FHIRServer", ..#Endpoint)
    If $$$ISERR(sc) Quit sc

    Write "Loading FHIR practitioner resources from "_..#PractitionerDataPath, !
    Set sc = ##class(HS.FHIRServer.Tools.DataLoader).SubmitResourceFiles(..#PractitionerDataPath, "FHIRServer", ..#Endpoint)
    If $$$ISERR(sc) Quit sc

    Write "Loading FHIR patient resources from "_..#PatientDataPath, !
    Set sc = ##class(HS.FHIRServer.Tools.DataLoader).SubmitResourceFiles(..#PatientDataPath, "FHIRServer", ..#Endpoint)
    If $$$ISERR(sc) Quit sc

    Write "FHIR resources loaded successfully.", !
    Quit $$$OK
}

}
