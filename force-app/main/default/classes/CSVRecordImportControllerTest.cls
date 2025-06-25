@isTest
public class CSVRecordImportControllerTest {

    static Opportunity setupTestData() {
        Account acc = new Account(
            Name='Test Biz Account',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByName().get('Business').getRecordTypeId(),
            Type = 'HQ',
            Number_of_Locations__c = '1-9',
            ShippingCountryCode = 'US'
            );

        insert acc;

        Opportunity opp = new Opportunity(
            Name='Test Opp',
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByName().get('Partnership').getRecordTypeId(),
            StageName='Engaged',
            LeadSource = 'Inbound',
            CloseDate= Date.today() + 30,
            AccountId=acc.Id,
            MSA__c = '1 - New York Metro',
            Type = 'New Partner'
        );

        insert opp;

        return opp;
    }

    static String setCSVContent() {
        return 'Class Name,Drop In Rate,Duration (Minutes),F&B Genre,Percent Payout,Pricing Input Amount,Pricing Input Type,Pricing Plan,Static Payout Rate\ntest class,10,15,Pizza,5,10,Membership Price,Static,1';
    }

    static Map<String, String> setCSVRow() {
        Map<String, String> row = new Map<String, String>{
            'Class Name' => 'test class',
            'Drop In Rate' => '10',
            'Duration (Minutes)' => '15',
            'F&B Genre' => 'Pizza',
            'Percent Payout' => '5',
            'Pricing Input Amount' => '10',
            'Pricing Input Type' => 'Membership Price',
            'Pricing Plan' => 'Static',
            'Static Payout Rate' => '1'
        };
        return row;
    }

    static Map<String, String> setFieldMapping() {
        Map<String, String> fieldMapping = new Map<String, String>{
            'Class_Name__c' => 'Class Name',
            'Drop_In_Rate__c' => 'Drop In Rate',
            'Duration_Minutes__c' => 'Duration (Minutes)',
            'F_B_Genre__c' => 'F&B Genre',
            'Percent_Payout__c' => 'Percent Payout',
            'Pricing_Input_Amount__c' => 'Pricing Input Amount',
            'Pricing_Input_Type__c' => 'Pricing Input Type',
            'Pricing_Plan__c' => 'Pricing Plan',
            'Static_Payout_Rate2__c' => 'Static Payout Rate'
        };
        return fieldMapping;
    }

    @isTest
    static void testProcessRecordImport_Success() {
        // 1. Create test data
        Opportunity opp = setupTestData();

        // 2. Set mapping metadata object
        String mappingMetadataObject = 'Class_Import_Field_Mapping__mdt';

        // 3. Prepare CSV content and rows
        String csvContent = setCSVContent();
        List<Map<String, String>> csvRows = new List<Map<String, String>>();
        Map<String, String> row = setCSVRow();
        csvRows.add(row);

        // 4. Prepare field mapping
        Map<String, String> fieldMapping = setFieldMapping();

        // 5. Call processRecordImport
        Test.startTest();
        CSVRecordImportController.ImportResult result = CSVRecordImportController.processRecordImport(
            opp.Id,
            'Opportunity__c',
            'Class__c',
            mappingMetadataObject,
            csvContent,
            'test.csv',
            csvRows,
            fieldMapping
        );
        Test.stopTest();

        // 6. Assert ImportResult
        Assert.areEqual(true, result.success, 'Import should succeed');
        Assert.areEqual(opp.Id, result.parentId, 'ParentId should match');
        Assert.areEqual(1, result.totalRows, 'Should process 1 row');
        Assert.areEqual(1, result.successRows, 'Should succeed 1 row');
        Assert.areEqual(0, result.failedRows, 'Should have 0 failed rows');
        Assert.areEqual(0, result.errors.size(), 'Should have no errors');

        // 7. Assert inserted SObject
        List<SObject> imported = Database.query('SELECT Id, Opportunity__c, Class_Name__c, Drop_In_Rate__c, Duration_Minutes__c, F_B_Genre__c, Percent_Payout__c, Pricing_Input_Amount__c, Pricing_Input_Type__c, Pricing_Plan__c, Static_Payout_Rate2__c, Row_JSON__c FROM Class__c');
        Assert.areEqual(1, imported.size(), 'Should insert 1 record');
        Assert.areEqual(opp.Id, imported[0].get('Opportunity__c'));
        Assert.areEqual('Pizza', imported[0].get('F_B_Genre__c'));
        Assert.areEqual(10, imported[0].get('Drop_In_Rate__c'));
        Assert.isNotNull(imported[0].get('Row_JSON__c'), 'Row_JSON__c should be populated');

        // 8. Assert ContentVersion created
        List<ContentVersion> cvs = [SELECT Id, Title, FirstPublishLocationId FROM ContentVersion WHERE Title = 'test.csv'];
        Assert.areEqual(1, cvs.size(), 'Should create ContentVersion');
        Assert.areEqual(opp.Id, cvs[0].FirstPublishLocationId);
    }

    // @isTest
    // static void testProcessRecordImport_InvalidMapping() {
    //     Opportunity opp = setupTestData();

    //     String mappingMetadataObject = 'Class_Import_Field_Mapping__mdt';
    //     //retrieveMappingMetadata(mappingMetadataObject);

    //     String csvContent = setCSVContent();
    //     List<Map<String, String>> csvRows = new List<Map<String, String>>();
    //     csvRows.add(new Map<String, String>{'Test Column'=>'Value1','Another Column'=>'Value2'});

    //     // Field mapping refers to a non-existent column
    //     Map<String, String> fieldMapping = new Map<String, String>{
    //         'Test_Field__c' => 'Nonexistent Column'
    //     };

    //     Test.startTest();
    //     CSVRecordImportController.ImportResult result = CSVRecordImportController.processRecordImport(
    //         opp.Id,
    //         'Opportunity__c',
    //         'Class__c',
    //         mappingMetadataObject,
    //         csvContent,
    //         'test2.csv',
    //         csvRows,
    //         fieldMapping
    //     );
    //     Test.stopTest();

    //     Assert.areEqual(true, result.success, 'Should still succeed (no required fields)');
    //     Assert.areEqual(1, result.totalRows);
    //     Assert.areEqual(1, result.successRows);
    //     Assert.areEqual(0, result.failedRows);
    //     Assert.areEqual(0, result.errors.size());
    // }

    @isTest
    static void testProcessRecordImport_InvalidObject() {
        Opportunity opp = setupTestData();

        String mappingMetadataObject = 'Class_Import_Field_Mapping__mdt';
        //retrieveMappingMetadata(mappingMetadataObject);

        String csvContent = setCSVContent();
        List<Map<String, String>> csvRows = new List<Map<String, String>>();
        Map<String, String> row = setCSVRow();
        csvRows.add(row);

        Map<String, String> fieldMapping = setFieldMapping();

        Boolean caught = false;
        try {
            CSVRecordImportController.processRecordImport(
                opp.Id,
                'Opportunity__c',
                'Nonexistent_Object__c',
                mappingMetadataObject,
                csvContent,
                'test3.csv',
                csvRows,
                fieldMapping
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Assert.isTrue(caught, 'Should throw AuraHandledException');
    }

    // @isTest
    // static void testProcessRecordImport_EmptyRows() {
    //     Opportunity opp = setupTestData();

    //     String mappingMetadataObject = 'Class_Import_Field_Mapping__mdt';
    //     //retrieveMappingMetadata(mappingMetadataObject);

    //     String csvContent = '';
    //     List<Map<String, String>> csvRows = new List<Map<String, String>>();

    //     Map<String, String> fieldMapping = new Map<String, String>();

    //     Test.startTest();
    //     CSVRecordImportController.ImportResult result = CSVRecordImportController.processRecordImport(
    //         opp.Id,
    //         'Opportunity__c',
    //         'Class__c',
    //         mappingMetadataObject,
    //         csvContent,
    //         'test4.csv',
    //         csvRows,
    //         fieldMapping
    //     );
    //     Test.stopTest();

    //     Assert.areEqual(true, result.success, 'Should succeed with no rows');
    //     Assert.areEqual(0, result.totalRows);
    //     Assert.areEqual(0, result.successRows);
    //     Assert.areEqual(0, result.failedRows);
    //     Assert.areEqual(0, result.errors.size());
    // }

    @isTest
    static void testGetTargetFieldMappings() {
        String mappingMetadataObject = 'Class_Import_Field_Mapping__mdt';
        //retrieveMappingMetadata(mappingMetadataObject);

        Test.startTest();
        Map<String, List<String>> mappings = CSVRecordImportController.getTargetFieldMappings(mappingMetadataObject);
        Test.stopTest();

        Assert.isTrue(mappings.containsKey('Class_Name__c'), 'Should contain Class_Name__c');
        Assert.areEqual('Class Name', mappings.get('Class_Name__c')[0]);
    }

    @isTest
    static void testGetDefaultFieldMapping() {
        String mappingMetadataObject = 'Class_Import_Field_Mapping__mdt';
        //(mappingMetadataObject);

        Test.startTest();
        Map<String, String> defaults = CSVRecordImportController.getDefaultFieldMapping(mappingMetadataObject);
        Test.stopTest();

        Assert.isTrue(defaults.containsKey('Class_Name__c'), 'Should contain default mapping for Class_Name__c');
        Assert.areEqual('Class Name', defaults.get('Class_Name__c'));
    }

    @isTest
    static void testGetAvailableFields() {
        String mappingMetadataObject = 'Class_Import_Field_Mapping__mdt';
        //retrieveMappingMetadata(mappingMetadataObject);

        Test.startTest();
        List<CSVRecordImportController.FieldInfo> fields = CSVRecordImportController.getAvailableFields('Class__c', mappingMetadataObject);
        Test.stopTest();

        Assert.isTrue(fields.size() > 0, 'Should return at least one field');
        Boolean found = false;
        for (CSVRecordImportController.FieldInfo f : fields) {
            if (f.apiName == 'Class_Name__c') found = true;
        }
        Assert.isTrue(found, 'Should include Class_Name__c field');
    }
}