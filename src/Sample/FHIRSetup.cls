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
    If ..FHIRRepositoryHasResources() {
        Write "FHIR repository already contains resources; skipping FHIR endpoint install and data load.", !
        Quit $$$OK
    }

    If '..FHIRRepositoryExists() {
        Write "Installing FHIR endpoint "_..#Endpoint, !
        Set packages = $ListBuild(..#CorePackage)
        Do ##class(HS.FHIRServer.Installer).InstallInstance(..#Endpoint, ..#StrategyClass, packages)
    } Else {
        Write "FHIR repository already exists; skipping FHIR endpoint install.", !
    }

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

ClassMethod FHIRRepositoryExists() As %Boolean [ Internal ]
{
    Quit:..FHIRResourceTableSchema()'="" 1
    Quit 0
}

ClassMethod FHIRRepositoryHasResources() As %Boolean [ Internal ]
{
    Set schema = ..FHIRResourceTableSchema()
    Quit:schema="" 0
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "select top 1 ID from "_schema_".Rsrc where Deleted=0")
    Quit:rs.%SQLCODE<0 0
    Quit rs.%Next()
}

ClassMethod FHIRResourceTableSchema() As %String [ Internal ]
{
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "select top 1 TABLE_SCHEMA from INFORMATION_SCHEMA.TABLES where TABLE_SCHEMA %MATCHES 'HSFHIR*_R' and TABLE_NAME='Rsrc' order by TABLE_SCHEMA")
    Quit:rs.%SQLCODE<0 ""
    Quit:rs.%Next() rs.%GetData(1)
    Quit ""
}

}
