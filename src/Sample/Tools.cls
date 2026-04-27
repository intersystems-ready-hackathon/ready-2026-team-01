Class Sample.Tools Extends %AI.Tool
{

/// Tool to add a person to the database
Method AddPerson(name As %String, age As %Integer){
    Set person = ##class(Sample.Person).%New()
    Set person.Name = name
    Set person.Age = age
    Do person.%Save()
}
/// Tool query database for people younger than a specified age
Query GetPeopleYoungerThan(age As %Integer) As %SQLQuery(
    ROWSPEC = "Name:%String,Age:%Integer") [ SqlProc ]
{
    SELECT Name, Age From Sample.Person Where Age < :age
}

/// Analyze FHIR data for privacy, reference, semantic, temporal, terminology,
/// clinical-note, and plausibility anomalies. This tool is read-only: it never modifies
/// the data. By default it reads resources from the IRIS for Health FHIR repository
/// in the FHIRSERVER namespace. args.bundle can still be supplied for direct Bundle
/// analysis. Optional args: patientId, resourceType, resourceTypes, maxResources,
/// fhirNamespace, objective, policy, focus, maxFindings. Returns {"findings":[...]}.
Method FindAnomalies(args As %DynamicObject) As %DynamicObject
{
    Try {
        If '$IsObject(args) {
            Return {"findings": [], "error": "args must be a JSON object"}
        }

        Set bundle = args.%Get("bundle", "")
        If '$IsObject(bundle) {
            Set bundle = ..BuildFHIRRepositoryBundle(args)
            If bundle.%Get("error", "")'="" {
                Return {"findings": [], "error": (bundle.%Get("error"))}
            }
        }

        Set maxFindings = +args.%Get("maxFindings", 20)
        If maxFindings < 1 Set maxFindings = 20
        If maxFindings > 50 Set maxFindings = 50

        Set apiKey = $System.Util.GetEnviron("OPENAI_API_KEY")
        If apiKey = "" {
            Return {"findings": [], "error": "OPENAI_API_KEY is not set"}
        }

        Set provider = ##class(%AI.Provider).Create("openai", {"api_key": (apiKey)})
        Set agent = ##class(%AI.Agent).%New(provider)
        Set agent.Model = $Select($System.Util.GetEnviron("OPENAI_MODEL")'="":$System.Util.GetEnviron("OPENAI_MODEL"), 1:"gpt-5-nano")
        Set agent.SystemPrompt = ..AnomalySystemPrompt()

        Set context = ..BuildAnomalyContext(args, bundle, maxFindings)
        Set prompt = ..BuildAnomalyPrompt(context, maxFindings)
        Set session = agent.CreateSession()
        Set response = agent.Chat(session, prompt)

        Set parsed = ..ParseJsonObject(response.Content)
        If '$IsObject(parsed) {
            Return {
                "findings": [],
                "error": "LLM response was not valid JSON",
                "rawResponse": ($Extract(response.Content, 1, 2000))
            }
        }

        Set findings = parsed.%Get("findings", "")
        If '$IsObject(findings) Set findings = []

        Set result = {"findings": (..NormalizeFindings(findings, maxFindings))}
        If $IsObject(bundle.%Get("_source", "")) Set result.source = bundle.%Get("_source")
        Return result
    } Catch ex {
        Return {"findings": [], "error": (ex.DisplayString())}
    }
}

ClassMethod AnomalySystemPrompt() As %String [ Internal ]
{
    Return "You are a careful FHIR R4 data quality analyst. Identify anomalies in FHIR Bundles for AI-assisted cleanup workflows. You may reason about the data, but you must not rewrite the bundle. Return only JSON with a top-level findings array. Every finding must be precise, auditable, and include a JSON Pointer path when possible. Prefer high-confidence findings over broad speculation. Recommended actions must be one of: redact, remove, replace, normalize, link, unlink, shift_date, decode_attachment, manual_review, no_action. Suggested tools must be deterministic MCP tools such as remove_identifier, remove_patient_telecom, generalize_patient_address, remove_geolocation_extensions, remove_extension, shift_all_dates, replace_reference, remove_dangling_references, normalize_period, replace_coding, decode_attachment, redact_attachment_text, validate_bundle. Mark clinical, terminology, billing, or medication changes as requiresHumanReview=true unless the action is only inspection or redaction of direct identifiers."
}

ClassMethod BuildAnomalyPrompt(context As %DynamicObject, maxFindings As %Integer) As %String [ Internal ]
{
    Set schema = "{""findings"":[{""id"":""a1"",""severity"":""critical|high|medium|low"",""confidence"":""high|medium|low"",""resourceType"":""Patient"",""resourceId"":""optional id"",""path"":""/entry/0/resource/identifier/0"",""title"":""short title"",""explanation"":""why this matters"",""evidence"":{},""recommendedAction"":""redact|remove|replace|normalize|link|unlink|shift_date|decode_attachment|manual_review|no_action"",""suggestedTool"":""optional deterministic tool name"",""suggestedArgs"":{},""requiresHumanReview"":false}]}"
    Set prompt = "Analyze the following compact FHIR Bundle context and return at most "_maxFindings_" findings."_$Char(10,10)
    Set prompt = prompt_"Objective: "_context.%Get("objective", "Find data quality anomalies relevant to safe demo, deidentification, and clinical-quality review.")_$Char(10)
    Set prompt = prompt_"Policy: "_context.%Get("policy", "demo-cleaning")_$Char(10)
    Set prompt = prompt_"Focus: "_context.%Get("focus", "privacy,references,semantics,temporal,terminology,clinical_notes,plausibility")_$Char(10,10)
    Set prompt = prompt_"Output JSON schema shape:"_$Char(10)_schema_$Char(10,10)
    Set prompt = prompt_"Rules:"_$Char(10)
    Set prompt = prompt_"- Return JSON only, no markdown fences."_$Char(10)
    Set prompt = prompt_"- Use stable ids a1, a2, a3, ..." _$Char(10)
    Set prompt = prompt_"- Use JSON Pointer paths from the supplied evidence where available."_$Char(10)
    Set prompt = prompt_"- If no anomaly is credible, return {""findings"":[]}."_$Char(10)
    Set prompt = prompt_"- Do not invent resources or values not present in the context."_$Char(10,10)
    Set prompt = prompt_"FHIR context JSON:"_$Char(10)_context.%ToJSON()
    Return prompt
}

ClassMethod BuildAnomalyContext(args As %DynamicObject, bundle As %DynamicObject, maxFindings As %Integer) As %DynamicObject [ Internal ]
{
    Set context = {}
    Set context.objective = args.%Get("objective", "")
    Set context.policy = args.%Get("policy", "demo-cleaning")
    Set context.focus = ..ArrayToCsv(args.%Get("focus", ""))
    Set context.bundle = {
        "resourceType": (bundle.%Get("resourceType", "")),
        "id": (bundle.%Get("id", "")),
        "type": (bundle.%Get("type", "")),
        "timestamp": (bundle.%Get("timestamp", "")),
        "entryCount": 0
    }
    If $IsObject(bundle.%Get("_source", "")) Set context.source = bundle.%Get("_source")
    Set context.resources = []
    Set context.referenceIndex = {}
    Set context.references = []
    Set context.directIdentifierEvidence = []
    Set context.privacyEvidence = []
    Set context.temporalEvidence = []
    Set context.attachmentEvidence = []
    Set context.rawExcerpt = ""

    Set entries = bundle.%Get("entry", "")
    If $IsObject(entries) {
        Set context.bundle.entryCount = entries.%Size()
        Set limit = entries.%Size()
        If limit > 250 Set limit = 250
        For i=0:1:limit-1 {
            Set entry = entries.%Get(i)
            If '$IsObject(entry) Continue
            Set resource = entry.%Get("resource", "")
            If '$IsObject(resource) Continue
            Do ..SummarizeResource(context, resource, i, entry.%Get("fullUrl", ""))
        }
        If entries.%Size() > limit {
            Set context.truncated = 1
            Set context.truncationNote = "Only first "_limit_" of "_entries.%Size()_" bundle entries were summarized."
        }
    }

    Set raw = bundle.%ToJSON()
    Set context.rawExcerpt = $Extract(raw, 1, 20000)
    Return context
}

ClassMethod BuildFHIRRepositoryBundle(args As %DynamicObject) As %DynamicObject [ Internal ]
{
    Set namespace = args.%Get("fhirNamespace", "FHIRSERVER")
    If namespace="" Set namespace = "FHIRSERVER"
    If '..IsSafeSqlName(namespace) {
        Return {"error": "fhirNamespace must contain only letters, numbers, and underscores"}
    }

    Set maxResources = +args.%Get("maxResources", 250)
    If maxResources < 1 Set maxResources = 250
    If maxResources > 1000 Set maxResources = 1000

    Set patientId = args.%Get("patientId", "")
    Set resourceType = args.%Get("resourceType", "")
    Set resourceTypes = args.%Get("resourceTypes", "")

    New $Namespace
    Set $Namespace = namespace

    Set schema = args.%Get("resourceTableSchema", "")
    If schema="" Set schema = ..FindFHIRResourceTableSchema()
    If schema="" {
        Set message = "Could not find a FHIR repository resource table such as HSFHIR_X0001_R.Rsrc in namespace "_namespace
        Return {"error": (message)}
    }
    If '..IsSafeSqlName(schema) {
        Return {"error": "resourceTableSchema must contain only letters, numbers, and underscores"}
    }

    Set bundle = {
        "resourceType": "Bundle",
        "id": ("iris-fhir-repository-"_$ZDateTime($Horolog, 3, 1)),
        "type": "collection",
        "entry": [],
        "_source": {
            "kind": "iris-fhir-repository",
            "namespace": (namespace),
            "table": (schema_".Rsrc"),
            "patientId": (patientId),
            "maxResources": (maxResources)
        }
    }

    If patientId'="" {
        Do ..AppendFHIRRepositoryResources(bundle, ..PatientFHIRSQL(schema, patientId, maxResources), maxResources)
    } ElseIf resourceType'="" {
        If '..IsSafeSqlName(resourceType) Return {"error": "resourceType must contain only letters, numbers, and underscores"}
        Do ..AppendFHIRRepositoryResources(bundle, ..ResourceTypeFHIRSQL(schema, resourceType, maxResources), maxResources)
    } ElseIf $IsObject(resourceTypes) {
        Do ..AppendFHIRRepositoryResourcesByType(bundle, schema, resourceTypes, maxResources)
    } Else {
        Do ..AppendFHIRRepositoryResourcesByType(bundle, schema, ..DefaultFHIRAnomalyResourceTypes(), maxResources)
    }

    Do bundle.%Get("_source").%Set("resourceCount", bundle.entry.%Size())
    If bundle.entry.%Size()=0 {
        Do bundle.%Get("_source").%Set("warning", "No FHIR resources matched the repository query.")
    }
    Return bundle
}

ClassMethod FindFHIRResourceTableSchema() As %String [ Internal ]
{
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "select top 1 TABLE_SCHEMA from INFORMATION_SCHEMA.TABLES where TABLE_SCHEMA %MATCHES 'HSFHIR*_R' and TABLE_NAME='Rsrc' order by TABLE_SCHEMA")
    If rs.%SQLCODE<0 Return ""
    If rs.%Next() Return rs.%GetData(1)
    Return ""
}

ClassMethod DefaultFHIRAnomalyResourceTypes() As %DynamicArray [ Internal ]
{
    Return ["Patient","DocumentReference","Claim","ExplanationOfBenefit","Encounter","Condition","Observation","MedicationRequest"]
}

ClassMethod AppendFHIRRepositoryResourcesByType(bundle As %DynamicObject, schema As %String, resourceTypes As %DynamicArray, maxResources As %Integer) [ Internal ]
{
    If '$IsObject(resourceTypes) Return
    Set typeCount = resourceTypes.%Size()
    If typeCount < 1 Return
    Set perType = (maxResources \ typeCount) + 1
    If perType < 10 Set perType = 10

    For i=0:1:typeCount-1 {
        Quit:bundle.entry.%Size()>=maxResources
        Set rt = resourceTypes.%Get(i)
        If '..IsSafeSqlName(rt) Continue
        Do ..AppendFHIRRepositoryResources(bundle, ..ResourceTypeFHIRSQL(schema, rt, perType), maxResources)
    }
}

ClassMethod AppendFHIRRepositoryResources(bundle As %DynamicObject, sql As %String, maxResources As %Integer) [ Internal ]
{
    Set rs = ##class(%SQL.Statement).%ExecDirect(, sql)
    If rs.%SQLCODE<0 {
        Do bundle.%Get("_source").%Set("error", rs.%Message)
        Return
    }

    While rs.%Next() {
        Quit:bundle.entry.%Size()>=maxResources
        Set json = rs.%GetData(3)
        If json="" Continue
        Set resource = ..ParseJsonObject(json)
        If '$IsObject(resource) Continue
        Set rt = resource.%Get("resourceType", rs.%GetData(1))
        Set id = resource.%Get("id", rs.%GetData(2))
        Do bundle.entry.%Push({
            "fullUrl": (rt_"/"_id),
            "resource": (resource)
        })
    }
}

ClassMethod PatientFHIRSQL(schema As %String, patientId As %String, maxResources As %Integer) As %String [ Internal ]
{
    Set patientRef = "Patient/"_patientId
    Set urnRef = "urn:uuid:"_patientId
    Set jsonIdCompact = """id"":"""_patientId_""""
    Set jsonIdSpaced = """id"": """_patientId_""""
    Return "select top "_maxResources_" ResourceType,ResourceId,ResourceString from "_schema_".Rsrc where Deleted=0 and ((ResourceType='Patient' and (ResourceId="_..SqlLiteral(patientId)_" or ResourceString [ "_..SqlLiteral(jsonIdCompact)_" or ResourceString [ "_..SqlLiteral(jsonIdSpaced)_")) or ResourceString [ "_..SqlLiteral(patientRef)_" or ResourceString [ "_..SqlLiteral(urnRef)_") order by case when ResourceType='Patient' then 0 else 1 end, ID"
}

ClassMethod ResourceTypeFHIRSQL(schema As %String, resourceType As %String, maxResources As %Integer) As %String [ Internal ]
{
    Return "select top "_maxResources_" ResourceType,ResourceId,ResourceString from "_schema_".Rsrc where Deleted=0 and ResourceType="_..SqlLiteral(resourceType)_" order by ID"
}

ClassMethod SqlLiteral(value As %String) As %String [ Internal ]
{
    Return "'"_$Replace(value, "'", "''")_"'"
}

ClassMethod IsSafeSqlName(value As %String) As %Boolean [ Internal ]
{
    If value="" Return 0
    For i=1:1:$Length(value) {
        Set ch = $Extract(value, i)
        If '(ch?1A) && '(ch?1N) && (ch'="_") Return 0
    }
    Return 1
}

ClassMethod SummarizeResource(context As %DynamicObject, resource As %DynamicObject, entryIndex As %Integer, fullUrl As %String) [ Internal ]
{
    Set rt = resource.%Get("resourceType", "")
    Set id = resource.%Get("id", "")
    Set basePath = "/entry/"_entryIndex_"/resource"
    Set summary = {"resourceType": (rt), "id": (id), "fullUrl": (fullUrl), "path": (basePath)}

    If fullUrl'="" Do context.referenceIndex.%Set(fullUrl, rt_"/"_id)
    If (rt'="") && (id'="") Do context.referenceIndex.%Set(rt_"/"_id, rt_"/"_id)

    Do ..SummarizeIdentifiers(context, summary, resource, basePath)
    Do ..SummarizePatientPrivacy(context, summary, resource, basePath)
    Do ..SummarizeCommonDates(context, summary, resource, basePath)
    Do ..SummarizeReferences(context, summary, resource, basePath)
    Do ..SummarizeAttachments(context, summary, resource, basePath)
    Do context.resources.%Push(summary)
}

ClassMethod SummarizeIdentifiers(context As %DynamicObject, summary As %DynamicObject, resource As %DynamicObject, basePath As %String) [ Internal ]
{
    Set identifiers = resource.%Get("identifier", "")
    If '$IsObject(identifiers) Return
    Set out = []
    For i=0:1:identifiers.%Size()-1 {
        Set ident = identifiers.%Get(i)
        If '$IsObject(ident) Continue
        Set typeCode = ..FirstCodingCode(ident.%Get("type", ""))
        Set one = {
            "path": (basePath_"/identifier/"_i),
            "system": (ident.%Get("system", "")),
            "typeCode": (typeCode),
            "hasValue": ($Select(ident.%Get("value", "")'="":1, 1:0))
        }
        Do out.%Push(one)
        If ..IsDirectIdentifier(ident.%Get("system", ""), typeCode) {
            Do context.directIdentifierEvidence.%Push(one)
        }
    }
    If out.%Size()>0 Set summary.identifiers = out
}

ClassMethod SummarizePatientPrivacy(context As %DynamicObject, summary As %DynamicObject, resource As %DynamicObject, basePath As %String) [ Internal ]
{
    If resource.%Get("resourceType", "")'="Patient" Return

    Set telecom = resource.%Get("telecom", "")
    If $IsObject(telecom), telecom.%Size()>0 {
        Set summary.telecomCount = telecom.%Size()
        Do context.privacyEvidence.%Push({"path": (basePath_"/telecom"), "kind": "patient_telecom", "count": (telecom.%Size())})
    }

    Set address = resource.%Get("address", "")
    If $IsObject(address) {
        Set addresses = []
        For i=0:1:address.%Size()-1 {
            Set oneAddr = address.%Get(i)
            If '$IsObject(oneAddr) Continue
            Set addrSummary = {
                "path": (basePath_"/address/"_i),
                "hasLine": ($Select($IsObject(oneAddr.%Get("line", "")):1, 1:0)),
                "city": (oneAddr.%Get("city", "")),
                "state": (oneAddr.%Get("state", "")),
                "postalCode": (oneAddr.%Get("postalCode", "")),
                "country": (oneAddr.%Get("country", ""))
            }
            Do addresses.%Push(addrSummary)
            If addrSummary.hasLine {
                Do context.privacyEvidence.%Push({"path": (basePath_"/address/"_i_"/line"), "kind": "patient_street_address"})
            }
        }
        If addresses.%Size()>0 Set summary.addresses = addresses
    }

    Do ..SummarizeExtensions(context, summary, resource.%Get("extension", ""), basePath_"/extension")
}

ClassMethod SummarizeExtensions(context As %DynamicObject, summary As %DynamicObject, extensions As %Any, path As %String) [ Internal ]
{
    If '$IsObject(extensions) Return
    Set extOut = []
    For i=0:1:extensions.%Size()-1 {
        Set ext = extensions.%Get(i)
        If '$IsObject(ext) Continue
        Set url = ext.%Get("url", "")
        Do extOut.%Push({"path": (path_"/"_i), "url": (url)})
        If ($ZConvert(url, "L") [ "geolocation") || ($ZConvert(url, "L") [ "latitude") || ($ZConvert(url, "L") [ "longitude") {
            Do context.privacyEvidence.%Push({"path": (path_"/"_i), "kind": "geolocation_extension", "url": (url)})
        }
    }
    If extOut.%Size()>0 Set summary.extensions = extOut
}

ClassMethod SummarizeCommonDates(context As %DynamicObject, summary As %DynamicObject, resource As %DynamicObject, basePath As %String) [ Internal ]
{
    Set dates = []
    Set fields = ["birthDate","deceasedDateTime","date","authoredOn","issued","effectiveDateTime","recordedDate","onsetDateTime","abatementDateTime","created","billablePeriod"]
    For i=0:1:fields.%Size()-1 {
        Set field = fields.%Get(i)
        Set value = resource.%Get(field, "")
        If value="" Continue
        If $IsObject(value) {
            Do dates.%Push({"path": (basePath_"/"_field), "value": (value.%ToJSON())})
        } Else {
            Do dates.%Push({"path": (basePath_"/"_field), "value": (value)})
        }
    }
    If dates.%Size()>0 {
        Set summary.dates = dates
        Do context.temporalEvidence.%Push({"resourceType": (resource.%Get("resourceType","")), "resourceId": (resource.%Get("id","")), "dates": (dates)})
    }
}

ClassMethod SummarizeReferences(context As %DynamicObject, summary As %DynamicObject, resource As %DynamicObject, basePath As %String) [ Internal ]
{
    Set refs = []
    Do ..MaybeReference(refs, resource, "subject", basePath_"/subject")
    Do ..MaybeReference(refs, resource, "patient", basePath_"/patient")
    Do ..MaybeReference(refs, resource, "encounter", basePath_"/encounter")
    Do ..MaybeReference(refs, resource, "provider", basePath_"/provider")
    Do ..MaybeReference(refs, resource, "practitioner", basePath_"/practitioner")
    Do ..MaybeReference(refs, resource, "organization", basePath_"/organization")
    Do ..MaybeReference(refs, resource, "serviceProvider", basePath_"/serviceProvider")
    Do ..MaybeReference(refs, resource, "location", basePath_"/location")
    If refs.%Size()>0 {
        Set summary.references = refs
        For i=0:1:refs.%Size()-1 {
            Do context.references.%Push(refs.%Get(i))
        }
    }
}

ClassMethod MaybeReference(refs As %DynamicArray, resource As %DynamicObject, field As %String, path As %String) [ Internal ]
{
    Set value = resource.%Get(field, "")
    If '$IsObject(value) Return
    If value.%Get("reference", "")'="" {
        Do refs.%Push({"path": (path_"/reference"), "reference": (value.%Get("reference", ""))})
        Return
    }
    Try {
        For i=0:1:value.%Size()-1 {
            Set one = value.%Get(i)
            If $IsObject(one), one.%Get("reference", "")'="" {
                Do refs.%Push({"path": (path_"/"_i_"/reference"), "reference": (one.%Get("reference", ""))})
            }
        }
    } Catch ex {
    }
}

ClassMethod SummarizeAttachments(context As %DynamicObject, summary As %DynamicObject, resource As %DynamicObject, basePath As %String) [ Internal ]
{
    Set content = resource.%Get("content", "")
    If '$IsObject(content) Return
    Set attachments = []
    Try {
        For i=0:1:content.%Size()-1 {
            Set one = content.%Get(i)
            If '$IsObject(one) Continue
            Set attachment = one.%Get("attachment", "")
            If '$IsObject(attachment) Continue
            Set data = attachment.%Get("data", "")
            Set a = {
                "path": (basePath_"/content/"_i_"/attachment"),
                "contentType": (attachment.%Get("contentType", "")),
                "title": (attachment.%Get("title", "")),
                "hasData": ($Select(data'="":1, 1:0)),
                "dataLength": ($Length(data))
            }
            Do attachments.%Push(a)
            Do context.attachmentEvidence.%Push(a)
        }
    } Catch ex {
    }
    If attachments.%Size()>0 Set summary.attachments = attachments
}

ClassMethod FirstCodingCode(codeableConcept As %Any) As %String [ Internal ]
{
    If '$IsObject(codeableConcept) Return ""
    Set coding = codeableConcept.%Get("coding", "")
    If '$IsObject(coding) Return ""
    If coding.%Size()<1 Return ""
    Set first = coding.%Get(0)
    If '$IsObject(first) Return ""
    Return first.%Get("code", "")
}

ClassMethod IsDirectIdentifier(system As %String, typeCode As %String) As %Boolean [ Internal ]
{
    Set s = $ZConvert(system, "L")
    Set t = $ZConvert(typeCode, "U")
    If s["us-ssn" Return 1
    If s["passport" Return 1
    If s["driver" Return 1
    If t="SS" Return 1
    If t="DL" Return 1
    If t="PPN" Return 1
    Return 0
}

ClassMethod ArrayToCsv(value As %Any) As %String [ Internal ]
{
    If '$IsObject(value) Return value
    Set out = ""
    Try {
        For i=0:1:value.%Size()-1 {
            If out'="" Set out = out_","
            Set out = out_value.%Get(i)
        }
    } Catch ex {
    }
    Return out
}

ClassMethod ParseJsonObject(text As %String) As %Any [ Internal ]
{
    Set json = ..ExtractJson(text)
    If json="" Return ""
    Try {
        Return {}.%FromJSON(json)
    } Catch ex {
        Return ""
    }
}

ClassMethod ExtractJson(text As %String) As %String [ Internal ]
{
    Set value = $ZStrip(text, "<W")
    Set value = $ZStrip(value, ">W")
    If $Extract(value, 1, 7)="```json" {
        Set value = $Extract(value, 8, *)
    } ElseIf $Extract(value, 1, 3)="```" {
        Set value = $Extract(value, 4, *)
    }
    Set value = $ZStrip(value, "<W")
    Set value = $ZStrip(value, ">W")
    If $Extract(value, *-2, *)="```" Set value = $Extract(value, 1, *-3)
    Set value = $ZStrip(value, "<W")
    Set value = $ZStrip(value, ">W")
    Set start = $Find(value, "{")
    Set finish = $Length(value)
    While finish>0, $Extract(value, finish)'="}" {
        Set finish = finish-1
    }
    If (start<2) || (finish<start) Return value
    Return $Extract(value, start-1, finish)
}

ClassMethod NormalizeFindings(findings As %DynamicArray, maxFindings As %Integer) As %DynamicArray [ Internal ]
{
    Set out = []
    Try {
        Set limit = findings.%Size()
        If limit > maxFindings Set limit = maxFindings
        For i=0:1:limit-1 {
            Set f = findings.%Get(i)
            If '$IsObject(f) Continue
            If f.%Get("id", "")="" Set f.id = "a"_(i+1)
            If f.%Get("severity", "")="" Set f.severity = "medium"
            If f.%Get("confidence", "")="" Set f.confidence = "medium"
            If f.%Get("resourceType", "")="" Set f.resourceType = "Bundle"
            If f.%Get("path", "")="" Set f.path = "/"
            If f.%Get("title", "")="" Set f.title = "Potential anomaly"
            If f.%Get("explanation", "")="" Set f.explanation = "The model identified this item as requiring review."
            If f.%Get("recommendedAction", "")="" Set f.recommendedAction = "manual_review"
            If f.%Get("requiresHumanReview", "")="" Set f.requiresHumanReview = 1
            Do out.%Push(f)
        }
    } Catch ex {
    }
    Return out
}

}
