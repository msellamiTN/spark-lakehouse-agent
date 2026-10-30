from pyspark.sql import SparkSession

spark = (
    SparkSession.builder
    .appName("lakehouse-phase1-smoke-test")
    .master("spark://spark-master:7077")
    .config("spark.executor.instances", "2")
    .getOrCreate()
)

print("Spark version:", spark.version)
print("Spark master:", spark.sparkContext.master)

sample = spark.createDataFrame(
    [(1, "books", 19.90), (2, "electronics", 99.00), (3, "books", 12.50)],
    ["order_id", "category", "amount"],
)

sample.groupBy("category").sum("amount").show()

output_path = "/lakehouse/bronze/phase1_smoke_test"
sample.write.mode("overwrite").parquet(output_path)

check = spark.read.parquet(output_path)
assert check.count() == 3
print("PASS: Spark cluster, aggregation and Parquet write/read")

spark.stop()
