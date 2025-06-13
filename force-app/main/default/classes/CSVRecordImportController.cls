public with sharing class CSVRecordImportController {
    
    @AuraEnabled
    public static ImportResult processRecordImport(Id parentId, String parentField, String objectToCreate, String mappingMetadataObject, String csvContent, String fileName, List<Map<String, String>> csvRows, Map<String, String> fieldMapping) {
        ImportResult result = new ImportResult();
        Savepoint sp = Database.setSavepoint();
        
        try {
            
            // Attach the CSV file to the parent Opportunity record
            ContentVersion cv = new ContentVersion();
            cv.Title = fileName;
            cv.PathOnClient = fileName;
            cv.VersionData = Blob.valueOf(csvContent);
            cv.FirstPublishLocationId = parentId; // Attach to the Opportunity
            insert cv;
            
            // Process CSV rows and create Class records
            //List<Class__c> classes = new List<Class__c>();
            List<SObject> objectsToInsert = new List<SObject>();
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
                    SObject obj = Schema.getGlobalDescribe().get(objectToCreate).newSObject();
                    if (obj == null) {
                        throw new AuraHandledException('Invalid object type: ' + objectToCreate);
                    }
                    //Class__c cl = new Class__c();
                    
                    // Store the entire row data as JSON in the Row_JSON__c field
                    try {
                        String jsonData = JSON.serialize(row);
                        obj.put('Row_JSON__c', jsonData);
                        //cl.Row_JSON__c = jsonData;
                        System.debug('Row data stored as JSON: ' + jsonData.left(100) + '...');
                    } catch (Exception e) {
                        System.debug('Error serializing row to JSON: ' + e.getMessage());
                    }
                    
                    // Map CSV columns to record fields using the field mapping
                    obj.put(parentField, parentId);
                    //cl.Opportunity__c = parentId;
                    
                    System.debug('============ PROCESSING ROW ============');
                    System.debug('Field mapping received: ' + JSON.serialize(fieldMapping));
                    System.debug('CSV row data: ' + JSON.serialize(row));
                    System.debug('CSV columns in this row: ' + row.keySet());
                    
                    // Apply field mapping to map CSV columns to record fields
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
                                setFieldValue(obj, fieldName, fieldValue);
                            } else {
                                System.debug('Skipping field ' + fieldName + ' because CSV value is null, empty, or N/A: "' + fieldValue + '"');
                            }
                            
                        } else {
                            System.debug('CSV column not found in row: ' + csvColumnName);
                            System.debug('Available columns: ' + row.keySet());
                        }
                    }
                    
                    // Fallback: Try to find and set important fields directly if mapping failed
                    performDirectFieldMapping(obj, objectToCreate, mappingMetadataObject, row);
                    
                    // Final verification
                    System.debug('\n============ RECORD BEFORE INSERT ============');
                    logRecordFields(obj, mappingMetadataObject);
                    
                    objectsToInsert.add(obj);
                    successCount++;
                } catch (Exception e) {
                    failCount++;
                    errors.add('Row ' + (i + 2) + ': ' + e.getMessage());
                }
            }
            
            // Insert all records
            if (!objectsToInsert.isEmpty()) {
                List<Database.SaveResult> saveResults = Database.insert(objectsToInsert, false);
                
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
            result.parentId = parentId;
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
    private static void performDirectFieldMapping(SObject obj, String objectToCreate, String mappingMetadataObject, Map<String, String> row) {
        // Direct mapping for new field structure - only for target fields
        Map<String, List<String>> fieldMappings = getTargetFieldMappings(mappingMetadataObject);
        
        // Try to map fields directly
        for (String fieldApiName : fieldMappings.keySet()) {
            List<String> possibleColumns = fieldMappings.get(fieldApiName);
            
            // Check if field is already populated
            Object currentValue = obj.get(fieldApiName);
            if (currentValue != null && String.valueOf(currentValue).trim() != '') {
                continue; // Skip if already populated
            }
            
            // Try to find a matching column
            for (String columnName : possibleColumns) {
                if (row.containsKey(columnName)) {
                    String csvValue = row.get(columnName);
                    
                    // Only proceed if the CSV value is valid (not null, empty, or N/A)
                    if (csvValue != null && csvValue.trim() != '' && !csvValue.trim().equalsIgnoreCase('N/A')) {
                        setFieldValue(obj, fieldApiName, csvValue);
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
                    Object currentValue = obj.get(fieldApiName);
                    if (currentValue == null || String.valueOf(currentValue).trim() == '') {
                        setFieldValue(obj, fieldApiName, csvValue);
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
    public static Map<String, List<String>> getTargetFieldMappings(String mappingMetadataObject) {

        System.debug('Fetching target field mappings from: ' + mappingMetadataObject);
        Map<String, List<String>> targetFieldMappings = new Map<String, List<String>>();
        String query = 'SELECT Target_Field__c, Alias__c FROM ' + mappingMetadataObject;
        for (SObject mapping : Database.query(query)) {
            String targetField = (String)mapping.get('Target_Field__c');
            String alias = (String)mapping.get('Alias__c');
            if (targetFieldMappings.containsKey(targetField)) {
                targetFieldMappings.get(targetField).add(alias);
            } else {
                targetFieldMappings.put(targetField, new List<String>{ alias });
            }
        }
        
        return targetFieldMappings;
    }
    
    /**
     * Get the target field API names - centralized method
     */
    private static Set<String> getTargetFieldApiNames(String mappingMetadataObject) {

        Set<String> targetFieldApiNames = new Set<String>();
        targetFieldApiNames.addAll(getTargetFieldMappings(mappingMetadataObject).keySet());

        return targetFieldApiNames;
    }
    
    /**
     * Log record fields for debugging - only target fields
     */
    private static void logRecordFields(SObject obj, String mappingMetadataObject) {
        System.debug('=== RECORD FIELD VALUES ===');
        Set<String> targetFields = getTargetFieldApiNames(mappingMetadataObject);
        
        for (String fieldName : targetFields) {
            try {
                Object fieldValue = obj.get(fieldName);
                System.debug(fieldName + ' = ' + fieldValue);
            } catch (Exception e) {
                System.debug('Error getting field value for ' + fieldName + ': ' + e.getMessage());
            }
        }
    }
    
    public class ImportResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String parentId;
        @AuraEnabled public Integer totalRows;
        @AuraEnabled public Integer successRows;
        @AuraEnabled public Integer failedRows;
        @AuraEnabled public String processedDateTime;
        @AuraEnabled public List<String> errors;
    }
    
    // Helper method to set field value using dynamic field API name
    private static void setFieldValue(SObject record, String fieldName, String value) {
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
            Schema.DescribeFieldResult fieldDescribe = record.getSObjectType().getDescribe().fields.getMap().get(fieldName).getDescribe();
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
    public static Map<String, String> getDefaultFieldMapping(String mappingMetadataObject) {

        Map<String, String> defaultFieldMap = new Map<String, String>();
        String query = 'SELECT Target_Field__c, Alias__c FROM ' + mappingMetadataObject + ' WHERE Is_Default_Mapping__c = true';

        for (SObject mapping : Database.query(query)) {
            String targetField = (String)mapping.get('Target_Field__c');
            String alias = (String)mapping.get('Alias__c');
            if(!defaultFieldMap.containsKey(targetField)) {
                defaultFieldMap.put(targetField, alias);
            }
        }

        return defaultFieldMap;
    }
    
    @AuraEnabled
    public static List<FieldInfo> getAvailableFields(String objectToCreate, String mappingMetadataObject) {
        List<FieldInfo> result = new List<FieldInfo>();
        
        try {
            // Get fields from the Class__c object
            Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe().get(objectToCreate).getDescribe().fields.getMap();
            
            // Get only the target fields we want to show
            Set<String> targetFields = getTargetFieldApiNames(mappingMetadataObject);
            
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
}