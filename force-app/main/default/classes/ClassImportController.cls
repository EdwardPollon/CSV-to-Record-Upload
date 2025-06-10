public with sharing class ClassImportController {
    
    
    @AuraEnabled
    public static ImportResult processClassImport(Id opportunityId, String csvContent, String fileName, List<Map<String, String>> csvRows, Map<String, String> fieldMapping) {
        ImportResult result = new ImportResult();
        Savepoint sp = Database.setSavepoint();
        
        try {
            
            // Attach the CSV file to the parent Opportunity record
            ContentVersion cv = new ContentVersion();
            cv.Title = fileName;
            cv.PathOnClient = fileName;
            cv.VersionData = Blob.valueOf(csvContent);
            cv.FirstPublishLocationId = opportunityId; // Attach to the Opportunity
            insert cv;
            
            // Process CSV rows and create LAT Staging Row records
            List<Class__c> classes = new List<Class__c>();
            List<String> errors = new List<String>();
            Integer successCount = 0;
            Integer failCount = 0;
            
            // Log the full field mapping before processing
            System.debug('FULL FIELD MAPPING: ' + JSON.serialize(fieldMapping));
            Set<String> csvColumnKeys = new Set<String>();
            if (!csvRows.isEmpty() && csvRows[0] != null) {
                csvColumnKeys = csvRows[0].keySet();
            }
            System.debug('CSV COLUMNS IN FIRST ROW: ' + csvColumnKeys);
            
            // Validate field mapping - remove any invalid mappings
            Map<String, String> validatedFieldMapping = new Map<String, String>();
            for (String fieldName : fieldMapping.keySet()) {
                String csvColumn = fieldMapping.get(fieldName);
                if (csvColumn != null && csvColumn.trim() != '' && 
                    !csvColumn.trim().equalsIgnoreCase('N/A') && 
                    csvColumnKeys.contains(csvColumn)) {
                    validatedFieldMapping.put(fieldName, csvColumn);
                    System.debug('Valid mapping: ' + fieldName + ' -> ' + csvColumn);
                } else {
                    System.debug('Skipping invalid mapping: ' + fieldName + ' -> ' + csvColumn);
                }
            }
            
            System.debug('VALIDATED FIELD MAPPING: ' + JSON.serialize(validatedFieldMapping));
            
            for (Integer i = 0; i < csvRows.size(); i++) {
                try {
                    Map<String, String> row = csvRows[i];
                    Class__c cl = new Class__c();
                    
                    // Store the entire row data as JSON in the Row_JSON__c field
                    try {
                        String jsonData = JSON.serialize(row);
                        cl.Row_JSON__c = jsonData;
                        System.debug('Row data stored as JSON: ' + jsonData.left(100) + '...');
                    } catch (Exception e) {
                        System.debug('Error serializing row to JSON: ' + e.getMessage());
                    }
                    
                    // Map CSV columns to staging row fields using the field mapping
                    cl.Opportunity__c = opportunityId;
                    
                    System.debug('============ PROCESSING ROW ============');
                    System.debug('Field mapping received: ' + JSON.serialize(fieldMapping));
                    System.debug('CSV row data: ' + JSON.serialize(row));
                    System.debug('CSV columns in this row: ' + row.keySet());
                    
                    // Apply field mapping to map CSV columns to staging row fields
                    for (String fieldName : validatedFieldMapping.keySet()) {
                        String csvColumnName = validatedFieldMapping.get(fieldName);
                        System.debug('\n** Processing validated mapping: ' + fieldName + ' -> ' + csvColumnName);
                        
                        // Only set the field if the column exists in the CSV
                        if (row.containsKey(csvColumnName)) {
                            String fieldValue = row.get(csvColumnName);
                            System.debug('Found value for ' + csvColumnName + ': "' + fieldValue + '"');
                            
                            // Skip if the CSV value itself is N/A, null, or empty
                            if (fieldValue != null && fieldValue.trim() != '' && !fieldValue.trim().equalsIgnoreCase('N/A')) {
                                // Use the field mapping method
                                setFieldValue(cl, fieldName, fieldValue);
                            } else {
                                System.debug('Skipping field ' + fieldName + ' because CSV value is null, empty, or N/A: "' + fieldValue + '"');
                            }
                            
                        } else {
                            System.debug('CSV column not found in row: ' + csvColumnName);
                            System.debug('Available columns: ' + row.keySet());
                        }
                    }
                    
                    // Fallback: Try to find and set important fields directly if mapping failed
                    performDirectFieldMapping(cl, row);
                    
                    // Final verification
                    System.debug('\n============ CLASS BEFORE INSERT ============');
                    logClassFields(cl);
                    
                    classes.add(cl);
                    successCount++;
                } catch (Exception e) {
                    failCount++;
                    errors.add('Row ' + (i + 2) + ': ' + e.getMessage());
                }
            }
            
            // Insert all staging rows
            if (!classes.isEmpty()) {
                List<Database.SaveResult> saveResults = Database.insert(classes, false);
                
                for (Integer i = 0; i < saveResults.size(); i++) {
                    if (!saveResults[i].isSuccess()) {
                        failCount++;
                        successCount--;
                        for (Database.Error error : saveResults[i].getErrors()) {
                            errors.add('Row ' + (i + 2) + ': ' + error.getMessage());
                            System.debug('DATABASE ERROR: Row ' + (i + 2) + ': ' + error.getMessage());
                        }
                    }
                }
            }
            
            // Prepare result
            result.success = errors.isEmpty();
            result.opportunityId = opportunityId;
            result.totalRows = csvRows.size();
            result.successRows = successCount;
            result.failedRows = failCount;
            result.processedDateTime = System.now().format();
            result.errors = errors;
            
            
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Error processing LAT import: ' + e.getMessage());
        }
        
        return result;
    }
    
    /**
     * Perform direct field mapping for new column structure
     */
    private static void performDirectFieldMapping(Class__c cl, Map<String, String> row) {
        // Direct mapping for new field structure - only for target fields
        Map<String, List<String>> fieldMappings = getTargetFieldMappings();
        
        // Try to map fields directly
        for (String fieldApiName : fieldMappings.keySet()) {
            List<String> possibleColumns = fieldMappings.get(fieldApiName);
            
            // Check if field is already populated
            Object currentValue = cl.get(fieldApiName);
            if (currentValue != null && String.valueOf(currentValue).trim() != '') {
                continue; // Skip if already populated
            }
            
            // Try to find a matching column
            for (String columnName : possibleColumns) {
                if (row.containsKey(columnName)) {
                    String csvValue = row.get(columnName);
                    
                    // Only proceed if the CSV value is valid (not null, empty, or N/A)
                    if (csvValue != null && csvValue.trim() != '' && !csvValue.trim().equalsIgnoreCase('N/A')) {
                        setFieldValue(cl, fieldApiName, csvValue);
                        System.debug('Direct mapping success: ' + fieldApiName + ' = ' + csvValue);
                        break;
                    } else {
                        System.debug('Skipping direct mapping for ' + fieldApiName + ' because CSV value is invalid: "' + csvValue + '"');
                    }
                }
            }
        }
        
        // Also check for exact matches with different casing
        for (String csvColumn : row.keySet()) {
            String csvValue = row.get(csvColumn);
            
            // Skip if CSV value is invalid
            if (csvValue == null || csvValue.trim() == '' || csvValue.trim().equalsIgnoreCase('N/A')) {
                continue;
            }
            
            String normalizedColumn = csvColumn.toLowerCase().replace(' ', '_').replace('-', '_');
            
            // Check against our field API names (without __c)
            for (String fieldApiName : fieldMappings.keySet()) {
                String normalizedFieldName = fieldApiName.toLowerCase().replace('__c', '');
                
                if (normalizedColumn.equals(normalizedFieldName) || 
                    normalizedColumn.replace('_', '').equals(normalizedFieldName.replace('_', ''))) {
                    
                    // Check if field is already populated
                    Object currentValue = cl.get(fieldApiName);
                    if (currentValue == null || String.valueOf(currentValue).trim() == '') {
                        setFieldValue(cl, fieldApiName, csvValue);
                        System.debug('Normalized mapping success: ' + fieldApiName + ' = ' + csvValue);
                    }
                }
            }
        }
    }
    
    /**
     * Get the target field mappings - centralized method
     */
    @AuraEnabled
    public static Map<String, List<String>> getTargetFieldMappings() {
        // return new Map<String, List<String>>{
        //     'DHS_Unique_Traveler_ID__c' => new List<String>{'DHS_Unique_Traveler_IDc', 'DHS Unique Traveler ID', 'Traveler ID', 'Unique ID'},
        //     'First_Name__c' => new List<String>{'FirstName', 'First Name', 'First_Name', 'FIRSTNAME'},
        //     'Middle_Name__c' => new List<String>{'MiddleName', 'Middle Name', 'Middle_Name', 'MIDDLENAME'},
        //     'Last_Name__c' => new List<String>{'LastName', 'Last Name', 'Last_Name', 'LASTNAME', 'Surname'},
        //     'Date_of_Birth__c' => new List<String>{'Birthdate', 'Birth Date', 'Date of Birth', 'DOB', 'BirthDate'},
        //     'Gender__c' => new List<String>{'GenderIdentity', 'Gender Identity', 'Gender', 'Sex'},
        //     'Nationality__c' => new List<String>{'Nationalityc', 'Nationality', 'Nation'},
        //     'Country_of_Citizenship__c' => new List<String>{'Country_of_Citizenshipc', 'Country of Citizenship', 'Citizenship'},
        //     'Primary_Language__c' => new List<String>{'Primary_Languagec', 'Primary Language', 'Language'},
        //     'Secondary_Language_s__c' => new List<String>{'Secondary_Language_sc', 'Secondary Language', 'Second Language'},
        //     'Email_Address__c' => new List<String>{'Email', 'Email Address', 'Contact Email'},
        //     'U_S_Phone_Number__c' => new List<String>{'Phone', 'Phone Number', 'Contact Number', 'Mobile'},
        //     'Emergency_Contact_Information__c' => new List<String>{'Emergency_Contact_Informationc', 'Emergency Contact Information', 'Emergency Contact'},
        //     'Travel_Document_Type__c' => new List<String>{'Travel_Document_Typec', 'Travel Document Type', 'Document Type'},
        //     'Travel_Document_Number__c' => new List<String>{'Travel_Document_Numberc', 'Travel Document Number', 'Document Number', 'Passport Number'},
        //     'Issuing_Country__c' => new List<String>{'Issuing_Countryc', 'Issuing Country', 'Document Issuing Country'},
        //     'Travel_Document_Expiration_Date__c' => new List<String>{'Travel_Document_Expiration_Datec', 'Travel Document Expiration Date', 'Document Expiry'},
        //     'Travel_Document_Status__c' => new List<String>{'Travel_Document_Statusc', 'Travel Document Status', 'Document Status'},
        //     'Photograph__c' => new List<String>{'Photographc', 'Photograph', 'Photo'},
        //     'Financial_Capability_Declaration__c' => new List<String>{'Financial_Capability_Declarationc', 'Financial Capability Declaration'},
        //     'Preferred_Destination_Country__c' => new List<String>{'Preferred_Destination_Countryc', 'Preferred Destination Country'},
        //     'Known_or_Alleged_Family_Relationships__c' => new List<String>{'Known_or_Alleged_Family_Relationshipsc', 'Known or Alleged Family Relationships'},
        //     'Special_Needs_Medical_Conditions__c' => new List<String>{'Special_Needs_Medical_Conditionsc', 'Special Needs Medical Conditions'},
        //     'Stipend_Eligibility_Flag__c' => new List<String>{'Stipend_Eligibility_Flagc', 'Stipend Eligibility Flag'},
        //     'ICE_CBP_Screening_Status__c' => new List<String>{'ICE_CBP_Screening_Statusc', 'ICE CBP Screening Status'},
        //     'Routing_Recommendation__c' => new List<String>{'Routing_Recommendationc', 'Routing Recommendation'},
        //     'Notes_Remarks__c' => new List<String>{'Notes_Remarksc', 'Notes Remarks', 'Notes', 'Remarks'}
        // };

        Map<String, List<String>> targetFieldMappings = new Map<String, List<String>>();
        
        for (Class_Import_Field_Mapping__mdt mapping : [SELECT Target_Field__c, Alias__c FROM Class_Import_Field_Mapping__mdt]) {
            String field = mapping.Target_Field__c;
            String alias = mapping.Alias__c;
            if (targetFieldMappings.containsKey(field)) {
                targetFieldMappings.get(field).add(alias);
            } else {
                targetFieldMappings.put(field, new List<String>{ alias });
            }
        }
        
        return targetFieldMappings;
    }
    
    /**
     * Get the target field API names - centralized method
     */
    private static Set<String> getTargetFieldApiNames() {
        // return new Set<String>{
        //     'DHS_Unique_Traveler_ID__c',
        //     'First_Name__c',
        //     'Middle_Name__c', 
        //     'Last_Name__c',
        //     'Date_of_Birth__c',
        //     'Gender__c',
        //     'Nationality__c',
        //     'Country_of_Citizenship__c',
        //     'Primary_Language__c',
        //     'Secondary_Language_s__c',
        //     'Email_Address__c',
        //     'U_S_Phone_Number__c',
        //     'Emergency_Contact_Information__c',
        //     'Travel_Document_Type__c',
        //     'Travel_Document_Number__c',
        //     'Issuing_Country__c',
        //     'Travel_Document_Expiration_Date__c',
        //     'Travel_Document_Status__c',
        //     'Photograph__c',
        //     'Financial_Capability_Declaration__c',
        //     'Preferred_Destination_Country__c',
        //     'Known_or_Alleged_Family_Relationships__c', 
        //     'Special_Needs_Medical_Conditions__c',
        //     'Stipend_Eligibility_Flag__c',
        //     'ICE_CBP_Screening_Status__c',
        //     'Routing_Recommendation__c',
        //     'Notes_Remarks__c'
        // };

        Set<String> targetFieldApiNames = new Set<String>();
        targetFieldApiNames.addAll(getTargetFieldMappings().keySet());

        return targetFieldApiNames;
    }
    
    /**
     * Log staging row fields for debugging - only target fields
     */
    private static void logClassFields(Class__c cl) {
        System.debug('=== STAGING ROW FIELD VALUES ===');
        Set<String> targetFields = getTargetFieldApiNames();
        
        for (String fieldName : targetFields) {
            try {
                Object fieldValue = cl.get(fieldName);
                System.debug(fieldName + ' = ' + fieldValue);
            } catch (Exception e) {
                System.debug('Error getting field value for ' + fieldName + ': ' + e.getMessage());
            }
        }
        
        System.debug('Row_JSON__c = ' + (cl.Row_JSON__c != null ? 'Populated (length: ' + cl.Row_JSON__c.length() + ')' : 'null'));
    }
    
    public class ImportResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String opportunityId;
        @AuraEnabled public Integer totalRows;
        @AuraEnabled public Integer successRows;
        @AuraEnabled public Integer failedRows;
        @AuraEnabled public String processedDateTime;
        @AuraEnabled public List<String> errors;
    }
    
    // Helper method to set field value using dynamic field API name
    private static void setFieldValue(Class__c record, String fieldName, String value) {
        // Enhanced logging
        System.debug('*** FIELD MAPPING ATTEMPT ***');
        System.debug('Field: ' + fieldName);
        System.debug('Value: ' + value);
        
        if (value == null || value.trim() == '' || value.trim() == 'N/A') {
            System.debug('SKIPPED: Empty, null, or N/A value');
            return;
        }
        
        try {
            // Handle different field types
            Schema.DescribeFieldResult fieldDescribe = Class__c.getSObjectType().getDescribe().fields.getMap().get(fieldName).getDescribe();
            Schema.DisplayType fieldType = fieldDescribe.getType();
            System.debug('Field Type: ' + fieldType);
            
            // Handle lookup/reference fields specially
            if (fieldType == Schema.DisplayType.REFERENCE) {
                System.debug('SKIPPED: Reference/Lookup field - cannot set with CSV value: ' + value);
                // Don't try to set lookup fields with CSV values
                return;
            }
            
            if (fieldType == Schema.DisplayType.DATE) {
                // Try to parse date value
                try {
                    Date dateValue;
                    try {
                        // Try standard Salesforce format YYYY-MM-DD
                        dateValue = Date.valueOf(value);
                        System.debug('Date parsed using valueOf: ' + dateValue);
                    } catch (Exception e1) {
                        System.debug('valueOf parse failed: ' + e1.getMessage());
                        try {
                            // Try MM/DD/YYYY
                            String[] parts = value.split('/');
                            System.debug('Date parts: ' + parts);
                            if (parts.size() == 3) {
                                Integer month = Integer.valueOf(parts[0]);
                                Integer day = Integer.valueOf(parts[1]);
                                Integer year = Integer.valueOf(parts[2]);
                                dateValue = Date.newInstance(year, month, day);
                                System.debug('Date parsed using MM/DD/YYYY: ' + dateValue);
                            }
                        } catch (Exception e2) {
                            System.debug('MM/DD/YYYY parse failed: ' + e2.getMessage());
                            try {
                                // Try DD/MM/YYYY
                                String[] parts = value.split('/');
                                if (parts.size() == 3) {
                                    Integer day = Integer.valueOf(parts[0]);
                                    Integer month = Integer.valueOf(parts[1]);
                                    Integer year = Integer.valueOf(parts[2]);
                                    dateValue = Date.newInstance(year, month, day);
                                    System.debug('Date parsed using DD/MM/YYYY: ' + dateValue);
                                }
                            } catch (Exception e3) {
                                System.debug('DD/MM/YYYY parse failed: ' + e3.getMessage());
                                System.debug('All date parsing attempts failed for: ' + value);
                                return;
                            }
                        }
                    }
                    record.put(fieldName, dateValue);
                    System.debug('Date field set: ' + fieldName + ' = ' + dateValue);
                } catch (Exception e) {
                    System.debug('Final date parsing exception: ' + e.getMessage());
                }
            } else if (fieldType == Schema.DisplayType.BOOLEAN) {
                // Handle boolean values
                String normalizedValue = value.toLowerCase().trim();
                Boolean boolValue = (normalizedValue == 'true' || normalizedValue == 'yes' || normalizedValue == '1' || normalizedValue == 'y');
                record.put(fieldName, boolValue);
                System.debug('Boolean field set: ' + fieldName + ' = ' + boolValue);
            } else if (fieldType == Schema.DisplayType.DOUBLE || fieldType == Schema.DisplayType.CURRENCY || 
                       fieldType == Schema.DisplayType.PERCENT || fieldType == Schema.DisplayType.INTEGER) {
                // Handle numeric types
                try {
                    String cleanValue = value.replaceAll('[^0-9.\\-]', '');
                    System.debug('Original numeric value: ' + value);
                    System.debug('Cleaned numeric value: ' + cleanValue);
                    if (cleanValue != '') {
                        Decimal numValue = Decimal.valueOf(cleanValue);
                        record.put(fieldName, numValue);
                        System.debug('Numeric field set: ' + fieldName + ' = ' + numValue);
                    }
                } catch (Exception e) {
                    System.debug('Numeric parsing failed: ' + e.getMessage());
                }
            } else if (fieldType == Schema.DisplayType.PHONE) {
                // Specific handling for phone fields
                String cleanPhone = value.replaceAll('[^0-9+\\-\\(\\)\\s]', '');
                record.put(fieldName, cleanPhone);
                System.debug('Phone field set: ' + fieldName + ' = ' + cleanPhone + ' (original: ' + value + ')');
            } else if (fieldType == Schema.DisplayType.EMAIL) {
                // Specific handling for email fields
                record.put(fieldName, value.trim());
                System.debug('Email field set: ' + fieldName + ' = ' + value.trim());
            } else {
                // For text and other types, just set the value directly
                record.put(fieldName, value);
                System.debug('Text field set: ' + fieldName + ' = ' + value);
            }
            
            // Verify the field was actually set
            try {
                Object setVal = record.get(fieldName);
                System.debug('SUCCESS: Field value after setting: ' + fieldName + ' = ' + setVal);
            } catch (Exception e) {
                System.debug('ERROR: Could not verify field was set: ' + e.getMessage());
            }
            
        } catch (Exception e) {
            System.debug('ERROR setting field ' + fieldName + ': ' + e.getMessage());
            System.debug('Exception type: ' + e.getTypeName());
            System.debug('Stack trace: ' + e.getStackTraceString());
        }
    }
    
    @AuraEnabled
    public static Map<String, String> getDefaultFieldMapping() {
        // Map<String, String> fieldMap = new Map<String, String>();
        // Updated field mapping for new column structure - only target fields
        // fieldMap.put('DHS_Unique_Traveler_ID__c', 'DHS_Unique_Traveler_IDc');
        // fieldMap.put('First_Name__c', 'FirstName');
        // fieldMap.put('Middle_Name__c', 'MiddleName');
        // fieldMap.put('Last_Name__c', 'LastName');
        // fieldMap.put('Date_of_Birth__c', 'Birthdate');
        // fieldMap.put('Gender__c', 'GenderIdentity');
        // fieldMap.put('Nationality__c', 'Nationalityc');
        // fieldMap.put('Country_of_Citizenship__c', 'Country_of_Citizenshipc');
        // fieldMap.put('Primary_Language__c', 'Primary_Languagec');
        // fieldMap.put('Secondary_Language_s__c', 'Secondary_Language_sc');
        // fieldMap.put('Email_Address__c', 'Email');
        // fieldMap.put('U_S_Phone_Number__c', 'Phone');
        // fieldMap.put('Emergency_Contact_Information__c', 'Emergency_Contact_Informationc');
        // fieldMap.put('Travel_Document_Type__c', 'Travel_Document_Typec');
        // fieldMap.put('Travel_Document_Number__c', 'Travel_Document_Numberc');
        // fieldMap.put('Issuing_Country__c', 'Issuing_Countryc');
        // fieldMap.put('Travel_Document_Expiration_Date__c', 'Travel_Document_Expiration_Datec');
        // fieldMap.put('Travel_Document_Status__c', 'Travel_Document_Statusc');
        // fieldMap.put('Photograph__c', 'Photographc');
        // fieldMap.put('Financial_Capability_Declaration__c', 'Financial_Capability_Declarationc');
        // fieldMap.put('Preferred_Destination_Country__c', 'Preferred_Destination_Countryc');
        // fieldMap.put('Known_or_Alleged_Family_Relationships__c', 'Known_or_Alleged_Family_Relationshipsc');
        // fieldMap.put('Special_Needs_Medical_Conditions__c', 'Special_Needs_Medical_Conditionsc');
        // fieldMap.put('Stipend_Eligibility_Flag__c', 'Stipend_Eligibility_Flagc');
        // fieldMap.put('ICE_CBP_Screening_Status__c', 'ICE_CBP_Screening_Statusc');
        // fieldMap.put('Routing_Recommendation__c', 'Routing_Recommendationc');
        // fieldMap.put('Notes_Remarks__c', 'Notes_Remarksc');
        // return fieldMap;

        // Updated field mapping for new column structure - only target fields
        Map<String, String> defaultFieldMap = new Map<String, String>();
        for (Class_Import_Field_Mapping__mdt mapping : [SELECT Target_Field__c, Alias__c FROM Class_Import_Field_Mapping__mdt WHERE Is_Default_Mapping__c = true]) {
            if(!defaultFieldMap.containsKey(mapping.Target_Field__c)) {
                defaultFieldMap.put(mapping.Target_Field__c, mapping.Alias__c);
            }
        }

        return defaultFieldMap;
    }
    
    @AuraEnabled
    public static List<FieldInfo> getAvailableFields() {
        List<FieldInfo> result = new List<FieldInfo>();
        
        try {
            // Get fields from the Class__c object
            Map<String, Schema.SObjectField> fieldMap = Class__c.getSObjectType().getDescribe().fields.getMap();
            
            // Get only the target fields we want to show
            Set<String> targetFields = getTargetFieldApiNames();
            
            System.debug('Available fields in Class__c: ' + fieldMap.keySet());
            System.debug('Target fields we are looking for: ' + targetFields);
            
            // Include only our target fields that actually exist on the object
            for (String fieldName : targetFields) {
                if (fieldMap.containsKey(fieldName)) {
                    Schema.DescribeFieldResult field = fieldMap.get(fieldName).getDescribe();
                    
                    FieldInfo info = new FieldInfo();
                    info.apiName = field.getName();
                    info.label = field.getLabel();
                    info.type = String.valueOf(field.getType());
                    result.add(info);
                    
                    System.debug('Added field: ' + info.apiName + ' (' + info.label + ')');
                } else {
                    System.debug('Target field not found in object: ' + fieldName);
                }
            }
            
            // Sort the results by field label for consistent display
            result.sort(new FieldInfoComparator());
            
            System.debug('Total fields returned: ' + result.size());
            
            if (result.isEmpty()) {
                throw new AuraHandledException('No target fields found on CLass__c object. Please ensure the required custom fields exist.');
            }
            
        } catch (Exception e) {
            System.debug('Error in getAvailableFields: ' + e.getMessage());
            throw new AuraHandledException('Error retrieving available fields: ' + e.getMessage());
        }
        
        return result;
    }
    
    // Comparator class for sorting FieldInfo by label
    public class FieldInfoComparator implements Comparator<FieldInfo> {
        public Integer compare(FieldInfo a, FieldInfo b) {
            if (a.label == null && b.label == null) return 0;
            if (a.label == null) return 1;
            if (b.label == null) return -1;
            return a.label.compareTo(b.label);
        }
    }
    
    // Class for field information
    public class FieldInfo {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
    }
    
    @AuraEnabled
    public static Boolean saveFieldMapping(String mappingName, Map<String, String> fieldMapping) {
        try {
            // Save the field mapping in a custom metadata type or custom setting
            // This is a placeholder for actual implementation
            // In a real implementation, you would save this to a database
            
            System.debug('Saving field mapping: ' + mappingName);
            System.debug('Field mapping data: ' + JSON.serialize(fieldMapping));
            
            return true;
        } catch (Exception e) {
            System.debug('Error saving field mapping: ' + e.getMessage());
            throw new AuraHandledException('Error saving field mapping: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static Map<String, String> getFieldMapping(String mappingName) {
        try {
            // This is a placeholder for actual implementation
            // In a real implementation, you would retrieve this from a database
            
            System.debug('Loading field mapping: ' + mappingName);
            
            // For now, just return the default mapping
            Map<String, String> mapping = getDefaultFieldMapping();
            System.debug('Returned field mapping: ' + JSON.serialize(mapping));
            
            return mapping;
        } catch (Exception e) {
            System.debug('Error loading field mapping: ' + e.getMessage());
            throw new AuraHandledException('Error loading field mapping: ' + e.getMessage());
        }
    }
}