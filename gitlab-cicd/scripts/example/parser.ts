import * as XLSX from 'xlsx';
import * as pathModule from 'path';
import * as fs from 'fs';

export class CSharpParser {
    static Parse(path: string, arr: string[]) : void {
        const csPath = './cs';

        arr.forEach((excelFile) => {
            const excelPath = pathModule.join(path, excelFile);
            if (!fs.existsSync(excelPath)) {
                throw new Error(`File not found: ${excelPath}`);
            }

            try {
                const workbook = XLSX.readFile(excelPath);
                const sheetName = excelFile.split('.')[0];
                if (!workbook.SheetNames.includes(sheetName)) {
                    console.error(`Sheet not found: ${sheetName} in ${excelFile}`);
                    return;
                }

                if(sheetName == "Language") {
                    return;
                }

                if(!fs.existsSync(csPath)) {
                    fs.mkdirSync(csPath, {recursive: true});
                }

                const worksheet = workbook.Sheets[sheetName];
                const jsonRows: any[][] = XLSX.utils.sheet_to_json(worksheet, {header: 1});
                let idIndex = -1;
                for (let i = 0; i < jsonRows.length; i++) {
                    const columns = jsonRows[i].map((col: any) => String(col).trim());
                    if (columns.includes('Id')) {
                        idIndex = i;
                        break;
                    }
                }
                if (idIndex === -1) {
                    console.error(`'Id' column does not exist: ${sheetName}`);
                    return;
                }

                if (idIndex < 2) {
                    console.error(`Not enough header rows above 'Id' row in: ${sheetName} (idIndex=${idIndex})`);
                    return;
                }

                if(sheetName.endsWith("Setting"))
                {
                    CSharpParser.parseSettingTable(jsonRows, idIndex, sheetName, csPath);
                }
                else
                {
                    CSharpParser.parseNormalTable(jsonRows, idIndex, sheetName, csPath);
                }
            } catch (err) {
                console.error(`Error processing: ${excelFile}`, err);
                return;
            }
        });

        try {
            CSharpParser.parseDataManager(path, csPath);
        } catch (err) {
            console.error(`Error generating DataManager:`, err);
        }
    }

    static parseNormalTable(jsonRows: any[][], idIndex: number, sheetName: string, csPath: string) : void
    {
        // Extract field names, types, and valid schema
        const fieldsNames = jsonRows[idIndex];
        const types = jsonRows[idIndex - 1];
        const ignores = jsonRows[idIndex - 2];

        const dupDict: { [key: string]: number } = {};
        const builder: string[] = [];
        builder.push(`using System.Collections.Generic;`);
        builder.push(`using Newtonsoft.Json;`);
        builder.push(`namespace TableData`);
        builder.push(`{`);
        builder.push(`   public partial class ${sheetName}`);
        builder.push(`   {`);

        for(let i = 0; i < ignores.length; i++)
        {
            if (ignores[i] !== 'A' && ignores[i] !== 'C')
            {
                continue;
            }

            if (dupDict[fieldsNames[i]] === 1)
            {
                continue;
            }

            const camelCaseFieldName = CSharpParser.toCamelCase(fieldsNames[i]);
            if (types[i].startsWith('enum'))
            {
                if (types[i].includes('[]'))
                {
                    const enumType = types[i].split('enum[]: ');
                    builder.push(`       [JsonProperty("${camelCaseFieldName}")] public readonly ${enumType[1]}[] ${fieldsNames[i]};`);
                    dupDict[fieldsNames[i]] = 1;
                }
                else
                {
                    const enumType = types[i].split('enum: ');
                    builder.push(`       [JsonProperty("${camelCaseFieldName}")] public readonly ${enumType[1]} ${fieldsNames[i]};`);
                }
            }
            else if (types[i].startsWith('class'))
            {
                if (types[i].includes('[]'))
                {
                    builder.push(`       [JsonProperty("${camelCaseFieldName}")] public readonly int[] ${fieldsNames[i]};`);
                    dupDict[fieldsNames[i]] = 1;
                }
                else
                {
                    builder.push(`       [JsonProperty("${camelCaseFieldName}")] public readonly int ${fieldsNames[i]};`);
                }
            }
            else if (types[i].endsWith('[]'))
            {
                builder.push(`       [JsonProperty("${camelCaseFieldName}")] public readonly ${types[i]} ${fieldsNames[i]};`);
                dupDict[fieldsNames[i]] = 1;
            }
            else
            {
                builder.push(`       [JsonProperty("${camelCaseFieldName}")] public readonly ${types[i]} ${fieldsNames[i]};`);
            }
        }

        builder.push(`   }`);
        builder.push(``);
        builder.push(`   public partial class ${sheetName}Dic : CustomDic<int, ${sheetName}>`);
        builder.push(`   {`);
        builder.push(`       private ${sheetName}Dic(Dictionary<int, ${sheetName}> basedic) : base(basedic) { }`);
        builder.push(`       public static ${sheetName}Dic CreateDic(string stream)`);
        builder.push(`       {`);
        builder.push(`           var dic = new Dictionary<int, ${sheetName}>();`);
        builder.push(`           var jsonList = JsonConvert.DeserializeObject<List<${sheetName}>>(stream);`);
        builder.push(`           foreach (var data in jsonList)`);
        builder.push(`           {`);
        builder.push(`               dic.Add(data.Id, data);`);
        builder.push(`           }`);
        builder.push(`           return new ${sheetName}Dic(dic);`);
        builder.push(`       }`);
        builder.push(`   }`);
        builder.push(`}`);

        const csFilePath = pathModule.join(csPath, `${sheetName}.cs`);
        fs.writeFileSync(csFilePath, builder.join('\n'), 'utf-8');
    }

    static parseSettingTable(jsonRows: any[][], idIndex: number, sheetName: string, csPath: string) : void
    {
        const fieldsNames = jsonRows[idIndex];
        const types = jsonRows[idIndex - 1];
        const keyIndex = fieldsNames.findIndex((name: string) => name === "Key");
        const ValueIndex = fieldsNames.findIndex((name: string) => name === "Value");

        if (keyIndex === -1 || ValueIndex === -1) {
            console.error(`Required columns 'Key' or 'Value' not found in setting table: ${sheetName}`);
            return;
        }

        const builder: string[] = [];
        builder.push(`using System.Reflection;`);
        builder.push(`using Newtonsoft.Json.Linq;`);
        builder.push(`namespace TableData`);
        builder.push(`{`);
        builder.push(`   public class ${sheetName}`);
        builder.push(`   {`);
        for(let i = idIndex + 1; i < jsonRows.length; i++)
        {
            const dataRow = jsonRows[i];
            builder.push(`       public static ${types[ValueIndex]} ${dataRow[keyIndex]} { get; private set; }`);
        }
        builder.push(`       public static void UpdateData(string stream)`);
        builder.push(`       {`);
        builder.push(`          var type = typeof(${sheetName});`);
        builder.push(`          JArray jArray = JArray.Parse(stream);`);
        builder.push(`          foreach (var token in jArray)`);
        builder.push(`          {`);
        builder.push(`              if (token is JObject obj)`);
        builder.push(`              {`);
        builder.push(`                  string key = obj["key"]?.ToObject<string>();`);
        builder.push(`                  JToken valueToken = obj["value"];`);
        builder.push(`                  if (string.IsNullOrEmpty(key) || valueToken == null)`);
        builder.push(`                      continue;`);
        builder.push(`                  var field = type.GetProperty(key, BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);`);
        builder.push(`                  if (field != null && field.CanWrite)`);
        builder.push(`                  {`);
        builder.push(`                      object value = valueToken.ToObject(field.PropertyType);`);
        builder.push(`                      field.SetValue(null, value);`);
        builder.push(`                  }`);
        builder.push(`              }`);
        builder.push(`          }`);
        builder.push(`       }`);
        builder.push(`   }`);
        builder.push(`}`);

        const csFilePath = pathModule.join(csPath, `${sheetName}.cs`);
        fs.writeFileSync(csFilePath, builder.join('\n'), 'utf-8');
    }

    static parseDataManager(tablePath: string, csPath: string): void
    {
        let jsonFiles: string[];
        try {
            jsonFiles = fs.readdirSync(tablePath)
                .filter(file => file.endsWith('.xlsm') || file.endsWith('.xlsx') || file.endsWith('.xls'))
                .map(file => file.replace(/\.(xlsm|xlsx|xls)$/i, ''));
        } catch (err) {
            throw new Error(`Failed to read table directory '${tablePath}': ${err instanceof Error ? err.message : String(err)}`);
        }

        const fileName = 'DataManager';
        const builder: string[] = [];

        builder.push(`using System.Collections.Generic;`);
        builder.push(`using System.Reflection;`);
        builder.push(`public abstract class CustomDic<T, X> : System.Collections.ObjectModel.ReadOnlyDictionary<T, X>`);
        builder.push(`{`);
        builder.push(`   public CustomDic(Dictionary<T, X> basedic) : base(basedic)`);
        builder.push(`   {`);
        builder.push(`       TableParseEnd();`);
        builder.push(`   }`);
        builder.push(`   protected virtual void GenerateTableParse() { }`);
        builder.push(`   private void TableParseEnd()`);
        builder.push(`   {`);
        builder.push(`       GenerateTableParse();`);
        builder.push(`   }`);
        builder.push(`}`);
        builder.push(``);
        builder.push(`namespace TableData`);
        builder.push(`{`);
        builder.push(`   public partial class DataManager`);
        builder.push(`   {`);
        builder.push(`       public static DataManager Instance { get; private set; } = null;`);

        for (const fileName of jsonFiles)
        {
            if (fileName === 'Enum' || fileName === 'Language' || fileName.endsWith('Setting')) continue;
            builder.push(`       public ${fileName}Dic ${fileName}_Dic { get; private set; }`);
        }

        builder.push(`       public DataManager(Dictionary<string, string> jsonDicList)`);
        builder.push(`       {`);
        builder.push(`           Instance = null;`);
        builder.push(`           UpdateData(jsonDicList);`);
        builder.push(`           Instance = this;`);
        builder.push(`       }`);
        builder.push(`       public void UpdateData(Dictionary<string, string> jsonDicList)`);
        builder.push(`       {`);
        builder.push(`           var type = typeof(DataManager);`);
        builder.push(`           foreach (var data in jsonDicList)`);
        builder.push(`           {`);
        builder.push(`               var property = type.GetProperty(data.Key + "_Dic", BindingFlags.Public | BindingFlags.Instance);`);
        builder.push(`               if (property == null)`);
        builder.push(`                   continue;`);
        builder.push(`               var createMethod = property.PropertyType.GetMethod("CreateDic", BindingFlags.Public | BindingFlags.Static);`);
        builder.push(`               if (createMethod == null)`);
        builder.push(`                   continue;`);
        builder.push(`               var dicInstance = createMethod.Invoke(null, new object[] { data.Value });`);
        builder.push(`               property.SetValue(this, dicInstance);`);
        builder.push(`           }`);
        builder.push(`       }`);
        builder.push(`   }`);
        builder.push(`}`);

        try {
            const csFilePath = pathModule.join(csPath, `${fileName}.cs`);
            fs.writeFileSync(csFilePath, builder.join('\n'), 'utf-8');
        } catch (err) {
            throw new Error(`Failed to write DataManager.cs: ${err instanceof Error ? err.message : String(err)}`);
        }
    }

    static toCamelCase (str: string): string
    {
        return str
            .replace(/[-_\s]+/g, " ") // convert separators to spaces
            .replace(/([a-z])([A-Z])/g, "$1 $2") // add space between camelCase/pascalCase transitions
            .toLowerCase()
            .split(" ")
            .filter(Boolean)
            .map((word, index) =>
                index === 0 ? word : word.charAt(0).toUpperCase() + word.slice(1),
            )
            .join("");
    }
}

// ts-node parser.ts Path tableNames
const args = process.argv.slice(2);
if (args.length >= 2)
{
    const path = args[0];
    const arrArg = args[1];
    try {
        if(arrArg === 'all')
        {
            const files = fs.readdirSync(path)
                .filter(file => file.endsWith('.xlsm') || file.endsWith('.xlsx') || file.endsWith('.xls'));
            CSharpParser.Parse(path, files);
        }
        else
        {
            const arr = arrArg.split(',');
            CSharpParser.Parse(path, arr);
        }
    } catch (err) {
        console.error('Fatal error:', err instanceof Error ? err.message : String(err));
        process.exit(1);
    }
}
else
{
    console.log('Command format: ts-node parser.ts <excel file path> <excel file name1,excel file name2,...>');
    process.exit(1);
}
